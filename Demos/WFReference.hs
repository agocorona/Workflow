
module Main where
import Control.Workflow
import Data.TCache
import Control.Concurrent(threadDelay)
import System.IO (hFlush,stdout)
import Control.Concurrent
import qualified Data.ByteString.Lazy.Char8 as B
import Control.Monad.Trans


main= do
   syncWrite SyncManual
   (ref,ref2) <- exec1 "WFRef" $ do
             step $ return (1 :: Int)
             ref <- newWFRef  "bye initial value1"

             step $ return (3 :: Int)
             liftIO $ do
                 s <- atomically $ readWFRef ref
                 print s

             ref2 <- newWFRef  "bye initial value2"

             liftIO $ do
                 s <- atomically $ readWFRef ref2
                 print s
             return (ref,ref2)
   print ref
   print ref2
   atomically $ writeWFRef ref "hi final value1"
   s <- atomically $ readWFRef ref
   print s
   atomically $ writeWFRef ref2 "hi final value2"
   s <- atomically $ readWFRef ref2
   print s
   Just stat <- getWFHistory "WFRef" ()
   B.putStrLn $ showHistory stat
   syncCache
   atomically flushAll

   stat<- getWFHistory "WFRef" () `onNothing` error "stat not found"
   B.putStrLn $ showHistory stat
   s <- atomically $   readWFRef ref
   print s
   s <- atomically $   readWFRef ref2
   print s



