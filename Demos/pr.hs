
module Main where
import Control.Workflow
import Control.Concurrent(threadDelay)
import System.IO (hFlush,stdout)
import Data.Vector as V
import System.IO.Unsafe
import Control.Concurrent.MVar

count= unsafePerformIO $ newMVar 0

-- delayed evaluation of logged step values

instance Indexable (Vector a) where
 key= const "Vector"

mcount cart= do
     i <- step $ modifyMVar count (\n->  threadDelay 1000000>> print cart >> return (n+1, n `mod` 3))

     let newCart= cart V.// [(i, cart V.! i + 1 )]

     mcount newCart
     return ()

main= start  "count"  mcount (V.fromList [0,0,0 :: Int])

