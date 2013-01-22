module Pipe
    ( TSink
    , TSource
    , TPipe
    , newTPipe
    , writeTSink
    , readTSource
    ) where

import Control.Concurrent.STM

newtype TSink a = TSink (TChan a)
newtype TSource a = TSource (TChan a)
type TPipe a = (TSink a, TSource a)

writeTSink :: TSink a -> a -> STM ()
writeTSink (TSink chan) = writeTChan chan

readTSource :: TSource a -> STM a
readTSource (TSource chan) = readTChan chan

newTPipe :: STM (TPipe a)
newTPipe = do
    chan <- newTChan
    return (TSink chan, TSource chan)

