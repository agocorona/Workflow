
module Main where
import Control.Workflow
import Control.Concurrent(threadDelay)
import System.IO (hFlush,stdout)


mcount n= do step $  do
                       putStr (show n ++ " ")
                       hFlush stdout
                       threadDelay 1000000
             mcount (n+1)
             return () -- to specify the return type

main= exec1  "count"  $ mcount (0 :: Int)
