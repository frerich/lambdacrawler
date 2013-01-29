{-# LANGUAGE DeriveDataTypeable #-}
module Arguments
    ( Arguments(url, numParallelConnections)
    , parseArgs
    ) where

import Data.Data
import System.Console.CmdArgs

data Arguments = Arguments
    { url :: String
    , numParallelConnections :: Int
    }
    deriving (Data, Typeable)

argSpec :: Arguments
argSpec = Arguments
    { url = def &= typ "URL" &= argPos 0
    , numParallelConnections = 10 &= help "Maximum number of parallel HTTP connections"
    }
    &= program "lambdacrawler"
    &= summary "lambdacrawler 0.1.0.0"
    &= details ["Traverses a hierarchy of web pages and extracts information from the page hierarchy"]

parseArgs :: IO Arguments
parseArgs = cmdArgs argSpec

