-- TODO: Clean up imports
import Control.Concurrent
import Control.Exception (bracket, mask, try, SomeException)
import Control.Monad (when)
import Control.Monad.Loops (untilM)
import qualified Data.CaseInsensitive as CI
import Data.Conduit (runResourceT)
import Data.List (nub)
import Data.Function (on)
import Data.Maybe (maybeToList, catMaybes, fromJust)
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

debug :: Bool
debug = True

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
getLinksFrom3xxResponse _ (Response _ _ headers _) = maybeToList $ do
    lookup hLocation headers >>= parseAbsoluteURI . B.unpack

getLinksFromResponse :: URI -> Response BL.ByteString -> [URI]
getLinksFromResponse url r@(Response status _ _ _)
    | status == status200 = getLinksFrom200Response url r
    | status == status301 ||
      status == status302 ||
      status == status307 = getLinksFrom3xxResponse url r
    | status == status404 = []
    | otherwise           = error (show r)

getURL :: Manager -> URI -> IO (Response BL.ByteString)
getURL mgr url = do
    request <- parseUrl (uriAsString url)
    let request' = request { redirectCount = 0, checkStatus = \_ _ -> Nothing }
    runResourceT $ httpLbs request' mgr

getLinksForURL :: Manager -> URI -> IO [URI]
getLinksForURL mgr url = do
    response <- getURL mgr url
    return $ map normalizedURI $ getLinksFromResponse url response
    where
        -- For our purpose, URIs which just differ in the fragment part are equal
        normalizedURI :: URI -> URI
        normalizedURI uri = uri { uriFragment = "" }

workerThread :: Chan (Maybe URI) -> MVar (S.Set URI) -> [(URI -> Bool)] -> Manager -> IO ()
workerThread uriQueue seenURIsMV uriTests mgr = do
    -- Fetch next URI to crawl from the queue
    item <- readChan uriQueue
    case item of
        Just uri -> do
            -- Mark the URI as seen by adding it to the 'seenURIs' set
            modifyMVar_ seenURIsMV (return . S.insert uri)

            -- Fetch HTML page and extract all links
            links <- getLinksForURL mgr uri

            -- Weed out those links which we don't care about (links to pages
            -- on other domains, non-http links, etc.)
            let acceptableLinks = filter (satisfiesAll uriTests) links

            -- Weed out those links which we already visited
            seenURIs <- takeMVar seenURIsMV
            let unseenLinks = filter (\u -> u `S.notMember` seenURIs) acceptableLinks
            putMVar seenURIsMV $ seenURIs `S.union` (S.fromList unseenLinks)

            threadId <- myThreadId
            when debug (putStrLn $ show threadId ++ ": Crawled " ++ show uri ++ ": " ++ show (length links) ++ " links, " ++ show (length acceptableLinks) ++ " acceptable, " ++ show (length unseenLinks) ++ " unseen")

            -- Append all unseen links to our queue
            writeList2Chan uriQueue . map Just $ unseenLinks

            queueEmpty <- isEmptyChan uriQueue
            when queueEmpty $ writeChan uriQueue Nothing
            workerThread uriQueue seenURIsMV uriTests mgr

        Nothing -> do
            writeChan uriQueue Nothing
            return ()

hostName :: URI -> Maybe String
hostName uri = uriRegName `fmap` (uriAuthority uri)

satisfiesAll :: [(a -> Bool)] -> a -> Bool
satisfiesAll preds x = and . map ($ x) $ preds

forkWorkerThread :: IO () -> IO (MVar ())
forkWorkerThread io = do
    handle <- newEmptyMVar
    _ <- forkFinally io (\_ -> putMVar handle ())
    return handle

crawl :: URI -> [(URI -> Bool)] -> Int -> IO [URI]
crawl uri uriTests numThreads =
    withSocketsDo $ bracket (newManager def) closeManager $ \mgr -> do
        uriQueue <- newChan
        seenURIsMV <- newMVar S.empty

        writeChan uriQueue $ Just uri

        let thread = workerThread uriQueue seenURIsMV uriTests mgr
        threads <- sequence . map forkWorkerThread . replicate numThreads $ thread

        -- Wait on all clients to finish
        _ <- sequence $ map takeMVar threads

        seenURIs <- takeMVar seenURIsMV
        unseenURIs <- (readChan uriQueue) `untilM` (isEmptyChan uriQueue)

        return $ S.toList seenURIs ++ map fromJust unseenURIs

main :: IO ()
main = do
    args <- getArgs
    -- TODO: Support more features like 'Show dead links' or 'Only show
    -- links to files with a certain MIME type'.
    if null args
      then putStrLn "syntax: crawler.hs <url>"
      else case parseURI (head args) of
            Just uri -> do
                -- TODO: Support for https
                let httpTest = (== "http:") . uriScheme

                -- TODO: Support additional constraints (using wildcards?)
                -- on the command line to avoid descending into certain
                -- directories or the like.
                let hostTest = ((==) `on` hostName) uri

                links <- crawl uri [httpTest, hostTest] 10

                putStrLn $ "Got " ++ show (length links) ++ " links:"
                putStr $ unlines $ map uriAsString links
            Nothing -> putStr $ "Not a valid URI!"


