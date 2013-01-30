-- TODO: Clean up imports
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception (bracket, mask, try, SomeException)
import qualified Data.CaseInsensitive as CI
import Data.Conduit (runResourceT)
import Data.List (nub)
import Data.Function (on)
import Data.Maybe (maybeToList, catMaybes)
import Data.Ord (comparing)
import qualified Data.Set as S
import Network.HTTP.Conduit
import Network.HTTP.Types.Header
import Network.HTTP.Types.Status
import Network.Socket
import Network.URI
import Text.HTML.TagSoup
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as BL
import Pipe
import qualified Arguments as Arg

data Command = Scan URI
             | Stop

type LogFn = String -> IO ()

nullLog :: LogFn
nullLog _ = return ()

simpleLog :: LogFn
simpleLog = putStrLn

-- Need this instance to be able to hold URI values in a Set; could
-- get rid of this orphan instance by just requiring network-2.4 or newer.
-- Unfortunately, the latest Haskell platform (2012.4.0.0) comes with
-- network-2.3.1.0, so let's define this instance ourselves (and accept
-- the warning) in order to not require anything newer than what's
-- contained in the latestp latform.
instance Ord URI where
    compare = comparing show

-- Newer base package (4.6.0.0 or newer) has this, but currentl Haskell platform
-- (2012.4.0.0) ships with base-4.5.1.0; so let's define it ourselves.
forkFinally :: IO a -> (Either SomeException a -> IO ()) -> IO ThreadId
forkFinally action and_then =
   mask $ \restore ->
     forkIO $ try (restore action) >>= and_then

-- A header name I missed in Network.HTTP.Types.Header :-/
hRefresh :: HeaderName
hRefresh = CI.mk $ B.pack "Refresh"

-- Gets the URI from the value of a Refresh meta tag (or the
-- HTTP refresh header)
uriFromRefreshString :: String -> Maybe URI
uriFromRefreshString s = case dropWhile (/= '=') s of
    ('=':'\'':rest) -> parseAbsoluteURI $ init rest
    ('=':rest) -> parseAbsoluteURI rest
    _  -> Nothing

-- Like the Show instance for URI, but keeps the password in the string
uriAsString :: URI -> String
uriAsString uri = uriToString id uri ""

getLinksFrom200Response :: URI -> Response BL.ByteString -> [URI]
getLinksFrom200Response url (Response _ _ headers markup) =
    nub
    . catMaybes
    $ linkFromRefreshHeader : linkFromMetaTag : linksFromAElements
    where
        linksFromAElements = map (hrefToAbsoluteURI url) hrefsFromMarkup
            where
                hrefsFromMarkup = map (fromAttrib "href")
                                  . filter (isTagOpenName "a")
                                  . parseTags
                                  $ BL.unpack markup
                hrefToAbsoluteURI base href = do
                    parsedRef <- parseURIReference href
                    parsedRef `nonStrictRelativeTo` base

        linkFromRefreshHeader = lookup hRefresh headers >>= uriFromRefreshString . B.unpack

        linkFromMetaTag = Nothing -- XXX Implement me!

getLinksFrom3xxResponse :: URI -> Response BL.ByteString -> [URI]
getLinksFrom3xxResponse _ (Response _ _ headers _) = maybeToList $
    lookup hLocation headers >>= parseAbsoluteURI . B.unpack

getLinksFromResponse :: URI -> Response BL.ByteString -> [URI]
getLinksFromResponse url r@(Response status _ _ _)
    | status == status200                             = getLinksFrom200Response url r
    | status `elem` [status301, status302, status307] = getLinksFrom3xxResponse url r
    | status == status404                             = []
    | otherwise                                       = error (show r)

getLinksForURL :: Manager -> URI -> IO [URI]
getLinksForURL mgr url = do
    request <- parseUrl (uriAsString url)

    -- Adjust the request so that the httpLbs function doesn't perform
    -- any implicit redirects - we want to detect all redirections ourselves.
    -- Furthermore, define checkStatus so that it never yields any exceptions;
    -- instead, we can (have to!) look at the HTTP status code ourselves to
    -- decide what happened.
    let request' = request { redirectCount = 0, checkStatus = \_ _ -> Nothing }
    response <- runResourceT $ httpLbs request' mgr -- XXX response is not lazy!
    return $ map normalizedURI $ getLinksFromResponse url response
    where
        -- For our purpose, URIs which just differ in the fragment part are equal
        normalizedURI uri = uri { uriFragment = "" }

workerThread :: TChan Command -> TSink [URI] -> TVar (S.Set URI) -> [URI -> Bool] -> Manager -> LogFn -> IO ()
workerThread unseenQueue uriSink seenURISetVar uriTests mgr logFn = do
    item <- atomically $ readTChan unseenQueue

    case item of
        Scan uri -> do
            atomically $ modifyTVar seenURISetVar $ S.insert uri
            links <- getLinksForURL mgr uri
            let acceptableLinks = S.fromList $ filter (satisfiesAll uriTests) links

            unseenLinks <- atomically $ do
                seenURIs <- readTVar seenURISetVar
                let unseen = acceptableLinks `S.difference` seenURIs
                writeTVar seenURISetVar $ seenURIs `S.union` unseen
                return unseen

            logFn $ "Crawled " ++ uriAsString uri ++ ", "
                               ++ show (S.size acceptableLinks) ++ " links found, "
                               ++ show (S.size unseenLinks) ++ " unseen"

            atomically $ writeTSink uriSink $ S.toList unseenLinks

            workerThread unseenQueue uriSink seenURISetVar uriTests mgr logFn

        Stop -> do
            -- Put poison pill back for other workers to consume (yuck!)
            atomically $ unGetTChan unseenQueue Stop
            return ()

hostName :: URI -> Maybe String
hostName uri = uriRegName `fmap` uriAuthority uri

satisfiesAll :: [a -> Bool] -> a -> Bool
satisfiesAll preds x = all ($ x) preds

forkWorkerThread :: IO () -> IO (MVar ())
forkWorkerThread io = do
    handle <- newEmptyMVar
    _ <- forkFinally io (\_ -> putMVar handle ())
    return handle

crawl :: URI -> [URI -> Bool] -> Int -> LogFn -> IO [URI]
crawl uri uriTests numThreads logFn =
    withSocketsDo $ bracket (newManager def) closeManager $ \mgr -> do
        unseenQueue <- atomically newTChan
        (uriSink, uriSource) <- atomically newTPipe
        seenURISetVar <- atomically $ newTVar S.empty

        let thread = workerThread unseenQueue uriSink seenURISetVar uriTests mgr logFn
        threads <- mapM forkWorkerThread . replicate (max numThreads 1) $ thread

        links <- crawlURIs unseenQueue 0 uriSource [uri]

        atomically $ writeTChan unseenQueue Stop
        mapM_ takeMVar threads

        return links
    where
        crawlURIs unseenQueue unseenQueueLen uriSource uris = do
            let newQueueLen = unseenQueueLen + length uris
            if newQueueLen == 0
                then return uris
                else do
                    mapM_ (atomically . writeTChan unseenQueue . Scan) uris
                    minedLinks <- atomically $ readTSource uriSource
                    minedSubLinks <- crawlURIs unseenQueue (newQueueLen - 1) uriSource minedLinks
                    return $ uris ++ minedSubLinks
main :: IO ()
main = do
    args <- Arg.parseArgs
    case parseURI (Arg.url args) of
        Just uri -> do
            let httpTest = (`elem` ["http:", "https:"]) . uriScheme
            let hostTest = ((==) `on` hostName) uri
            let logFn = if (Arg.verbose args) then simpleLog else nullLog
            logFn $ "Starting to crawl at " ++ Arg.url args ++ " with up to " ++ show (Arg.numParallelConnections args) ++ " threads"
            links <- crawl uri [httpTest, hostTest] (Arg.numParallelConnections args) logFn
            putStrLn $ "Got " ++ show (length links) ++ " links:"
            putStr $ unlines $ map uriAsString links
        Nothing -> putStrLn "Not a valid URI!"


