-- TODO: Clean up imports
import Control.Concurrent.STM
import Control.Exception (bracket)
import Control.Concurrent.ThreadPool as ThreadPool
import qualified Data.CaseInsensitive as CI
import Data.Conduit (runResourceT)
import Data.List (nub)
import Data.Function (on)
import Data.Maybe (maybeToList, catMaybes)
import qualified Data.Set as S
import Network.HTTP.Conduit
import Network.HTTP.Types.Header
import Network.HTTP.Types.Status
import Network.Socket
import Network.URI
import Text.HTML.TagSoup
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Arguments as Arg

type LogFn = String -> IO ()

nullLog :: LogFn
nullLog _ = return ()

simpleLog :: LogFn
simpleLog = putStrLn

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
                    return $ parsedRef `nonStrictRelativeTo` base

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

hostName :: URI -> Maybe String
hostName uri = uriRegName `fmap` uriAuthority uri

satisfiesAll :: [a -> Bool] -> a -> Bool
satisfiesAll preds x = all ($ x) preds

visitURI :: Manager -> LogFn -> [URI -> Bool] -> TQueue [URI] -> TVar (S.Set URI) -> Pool URI -> URI -> IO ()
visitURI mgr logFn uriTests resultQueue seenURISetVar _ uri = do
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

    atomically $ writeTQueue resultQueue (S.toList unseenLinks)

    return ()

crawl :: Pool URI -> TQueue [URI] -> Int -> [URI] -> IO [URI]
crawl threadPool resultQueue numQueuedURIs uris = do
    let newNumQueuedURIs = numQueuedURIs + length uris
    if newNumQueuedURIs == 0
        then return uris
        else do
            mapM_ (ThreadPool.process threadPool) uris
            foundURIs <- atomically $ readTQueue resultQueue
            foundSubURIs <- crawl threadPool resultQueue (newNumQueuedURIs - 1) foundURIs
            return $ foundURIs ++ foundSubURIs

main :: IO ()
main = do
    args <- Arg.parseArgs
    case parseURI (Arg.url args) of
        Just uri -> do
            let httpTest = (`elem` ["http:", "https:"]) . uriScheme
            let hostTest = ((==) `on` hostName) uri
            let logFn = if (Arg.verbose args) then simpleLog else nullLog
            let numThreads = Arg.numParallelConnections args

            logFn $ "Starting to crawl at " ++ Arg.url args ++ " with up to " ++ show numThreads ++ " threads"

            resultQueue <- atomically $ newTQueue
            seenURIs <- atomically $ newTVar S.empty

            withSocketsDo $ bracket (newManager def) closeManager $ \mgr -> do
                threadPool <- ThreadPool.create numThreads (visitURI mgr logFn [httpTest, hostTest] resultQueue seenURIs)
                links <- crawl threadPool resultQueue 0 [uri]
                putStrLn $ "Got " ++ show (length links) ++ " links:"
                putStr $ unlines $ map uriAsString links

        Nothing -> putStrLn "Not a valid URI!"

