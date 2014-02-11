{-# LANGUAGE RecursiveDo #-}

-- | Implements a thread of pools which consumes data in the order it is
-- fed to the pool. A pool is created using the 'create' function. Afterwards,
-- use 'process' to feed data to the pool. Finally, use 'drain' to initialize
-- draining the pool and call 'wait' to wait for all threads to finish.
--
-- The worker threads get a handle to the pool on which they are working, so
-- they can feed new input to the pool or initialize draining the pool
-- themselves.
module Control.Concurrent.ThreadPool (
    create,
    process,
    drain,
    wait,
    Pool()
) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad

-- A command processed by the internal worker threads: either a thread
-- processes a piece of data, or it stops.
data Command a = Process a | Stop

-- | Represents a thread pool made up of an unspecified number of threads, each
-- of which is processing values of type 'a'.
data Pool a = Pool [MVar ()] (TQueue (Command a))

-- Small helper function; like forkIO, but yields an MVar
-- which we can try to take to join the thread.
forkThread :: IO () -> IO (MVar ())
forkThread proc = do
    handle <- newEmptyMVar
    _ <- forkFinally proc (\_ -> putMVar handle ())
    return handle

-- Wraps the user-specified thread procedure; it consumes
-- an element from the command queue and either stops or
-- processes the specified item.
worker :: Pool a -> (Pool a -> a -> IO ()) -> IO ()
worker pool@(Pool _ cmdQueue) proc = do
    cmd <- atomically $ readTQueue cmdQueue
    case cmd of
        Process item -> do
            proc pool item
            worker pool proc
        Stop -> do
            -- Feed the poison pill back to the queue so that it can
            -- be picked up by other worker threads.
            atomically $ unGetTQueue cmdQueue Stop
            return ()

-- | The 'create' function creates a new thread pool. The threads are
-- spawned immediately and start waiting for data to be processed. Use the
-- 'process' function to feed data to the thread pool.
--
-- Note that the function which processes the elements gets passed a handle
-- to the pool itself. This allows feeding new data or draining the thread
-- pool from the worker thread.
create :: Int                     -- ^ Number of threads in the pool; should not be lower than 1.
       -> (Pool a -> a -> IO ())  -- ^ Function which processes elements fed to the pool.
       -> IO (Pool a)             -- ^ The resulting thread pool
create numThreads proc = mdo
    cmdQueue <- atomically newTQueue

    let threadProc = worker pool proc
    threads <- replicateM numThreads (forkThread threadProc)

    let pool = Pool threads cmdQueue
    return pool

-- | The 'process' function passes a value to a thread pool for consumption. In
-- case all threads are busy, the value is queued. There is no maximum on the
-- number of values which can be queued.
process :: Pool a   -- ^ Pool to pass value to
        -> a        -- ^ The value to process
        -> IO ()
process (Pool _ cmdQueue) item = atomically $ writeTQueue cmdQueue (Process item)

-- | The 'drain' function starts draining the thread pool, i.e. all threads
-- in the pool will eventually stop running. Call 'wait' to wait until all
    -- threads finished processing data.
drain :: Pool a -> IO ()
drain (Pool _ cmdQueue) = atomically $ writeTQueue cmdQueue Stop

-- | The 'wait' function suspends the calling thread until all threads in the
-- given pool finished processing data. Do not call this from within a
-- worker thread to avoid a deadlock!
wait :: Pool a -> IO ()
wait (Pool threads _) = mapM_ takeMVar threads

