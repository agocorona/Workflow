-- counter that reify the step result (see the difference in logs generated
-- write the log every 4 elements so the last 3 elements can be lost
module Main where
import Control.Workflow
import Data.TCache
import Control.Concurrent(threadDelay)
import System.IO (hFlush,stdout)

mcount :: Int -> Workflow IO ()
mcount n= do n1 <- step $  do
                       putStr (show n ++ " ")
                       hFlush stdout
                       threadDelay 1000000
                       if n `rem` 4 == 0 then  syncCache else return ()
                       return n

             mcount (n1+1)


main= do
 syncWrite SyncManual
 exec1  "count1"  $ mcount (0 :: Int)

