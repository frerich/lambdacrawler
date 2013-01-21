-- TODO: Clean up imports
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception (bracket, mask, try, SomeException)
import Control.Monad (when)
import Control.Monad.Loops (untilM)
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
import System.Environment (getArgs)

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

getURL :: Manager -> URI -> IO (Response BL.ByteString)
getURL mgr url = do
    request <- parseUrl (uriAsString url)

    -- Adjust the request so that the httpLbs function doesn't perform
    -- any implicit redirects - we want to detect all redirections ourselves.
    -- Furthermore, define checkStatus so that it never yields any exceptions;
    -- instead, we can (have to!) look at the HTTP status code ourselves to
    -- decide what happened.
    let request' = request { redirectCount = 0, checkStatus = \_ _ -> Nothing }
    runResourceT $ httpLbs request' mgr

getLinksForURL :: Manager -> URI -> IO [URI]
getLinksForURL mgr url = do
    response <- getURL mgr url
    return $ map normalizedURI $ getLinksFromResponse url response
    where
        -- For our purpose, URIs which just differ in the fragment part are equal
        normalizedURI uri = uri { uriFragment = "" }

workerThread :: TChan (Maybe URI) -> TVar (S.Set URI) -> TVar Int -> [URI -> Bool] -> Manager -> IO ()
workerThread uriQueue seenURIsVar activeWorkersVar uriTests mgr = do
    item <- atomically $ do
        e <- readTChan uriQueue
        case e of
            Just u -> do
                modifyTVar activeWorkersVar (+1)
                return $ Just u
            Nothing ->
                return Nothing

    case item of
        Just uri -> do
            processURI uri
            atomically $ modifyTVar activeWorkersVar (subtract 1)

            -- The 'Nothing' is the poison pill: if it's read, a worker thread stops.
            done <- endOfInput
            when done $ atomically . writeTChan uriQueue $ Nothing

            workerThread uriQueue seenURIsVar activeWorkersVar uriTests mgr
        Nothing -> atomically $ writeTChan uriQueue Nothing

    where
        processURI uri = do
            atomically $ modifyTVar seenURIsVar $ S.insert uri
            links <- getLinksForURL mgr uri
            let acceptableLinks = filter (satisfiesAll uriTests) links

            unseenLinks <- atomically $ do
                seenURIs <- readTVar seenURIsVar
                let unseen = filter (`S.notMember` seenURIs) acceptableLinks
                writeTVar seenURIsVar $ seenURIs `S.union` S.fromList unseen
                return unseen

            mapM_ (atomically . writeTChan uriQueue . Just) unseenLinks

        -- There's no more input to be expected if no worker is active (every
        -- worker is also a producer of new URIs), and if there is nothing
        -- left in the URI queue.
        endOfInput = do
            queueEmpty <- atomically $ isEmptyTChan uriQueue
            activeWorkerCount <- readTVarIO activeWorkersVar
            return $ queueEmpty && activeWorkerCount == 0;

hostName :: URI -> Maybe String
hostName uri = uriRegName `fmap` uriAuthority uri

satisfiesAll :: [a -> Bool] -> a -> Bool
satisfiesAll preds x = all ($ x) preds

forkWorkerThread :: IO () -> IO (MVar ())
forkWorkerThread io = do
    handle <- newEmptyMVar
    _ <- forkFinally io (\_ -> putMVar handle ())
    return handle

crawl :: URI -> [URI -> Bool] -> Int -> IO [URI]
crawl uri uriTests numThreads =
    withSocketsDo $ bracket (newManager def) closeManager $ \mgr -> do
        uriQueue <- atomically newTChan
        seenURIsVar <- atomically $ newTVar S.empty
        activeWorkersVar <- atomically $ newTVar 0

        atomically $ writeTChan uriQueue $ Just uri

        let thread = workerThread uriQueue seenURIsVar activeWorkersVar uriTests mgr
        threads <- mapM forkWorkerThread . replicate numThreads $ thread

        -- Wait on all clients to finish
        mapM_ takeMVar threads

        seenURIs <- readTVarIO seenURIsVar
        unseenURIs <- atomically (readTChan uriQueue) `untilM` atomically (isEmptyTChan uriQueue)

        return $ S.toList seenURIs ++ catMaybes unseenURIs

main :: IO ()
main = do
    args <- getArgs
    if null args
      then putStrLn "syntax: crawler.hs <url>"
      else case parseURI (head args) of
            Just uri -> do
                let httpTest = (`elem` ["http:", "https:"]) . uriScheme
                let hostTest = ((==) `on` hostName) uri
                let numParallelConnections = 10
                links <- crawl uri [httpTest, hostTest] numParallelConnections
                putStrLn $ "Got " ++ show (length links) ++ " links:"
                putStr $ unlines $ map uriAsString links
            Nothing -> putStrLn "Not a valid URI!"


