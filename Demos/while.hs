
module Main where
import Control.Workflow
import Control.Concurrent(threadDelay)
import System.IO (hFlush,stdout)
import Data.IORef
import System.IO.Unsafe

rn= unsafePerformIO $ newIORef ( 0 :: Int)

main= exec1  "while"  $
         while ( < 20) $ step $ do
            n <- readIORef rn
            putStr (show n ++ " ")
            hFlush stdout
            threadDelay 1000000
            writeIORef rn (n+1)
            return $ n +1

