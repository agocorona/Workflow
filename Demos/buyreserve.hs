{-# LANGUAGE DeriveDataTypeable #-}

import Control.Workflow as WF
import Data.TCache
import Data.TCache.DefaultPersistence
import Control.Concurrent.STM
import Data.ByteString.Lazy.Char8(pack,unpack)
import Data.Typeable
import Control.Concurrent(forkIO,threadDelay, killThread)
import Control.Monad.IO.Class(liftIO)
import Control.Workflow.Stat
import Data.Maybe
import Data.Map (fromList)

import Debug.Trace
(!>)= flip trace

data Book= Book{btitle :: String, stock,reserved :: Int}
           deriving (Read,Show, Eq,Typeable)

instance Indexable Book where key= btitle

instance Serializable Book where
  serialize= pack. show
  deserialize= read . unpack

-- show
main= do

  putStrLn "\nFIRST CASE: the stock appears at 20 seconds.\n\
           \The WF is killed and restarted at 30 simulatingn\
           \a shutdown and restart.\n\
           \It is bought at 40.\n\
           \The reserve timeouts (at 50) is not reached.\n"
  test 20  40 50 30

  putStrLn "press any key to start the second case"
  getChar

  putStrLn "\nSECOND CASE: the stock appears at 20. \n\
           \It is killed at 10 simulating a shutdowm\
           \and restart.\n\
           \It is bought at 60, after the end of the \
           \reserve (20+25)\n"
  test 20 60 25 10

  putStrLn "press a letter to start the third case"
  getChar

  putStrLn "\nTHIRD CASE: the product enter in stock at 25,\
           \nwhen the reservation period was finished.\n\
           \At 30 but the buyer appears shortly after and\
           \buy the product.\n\
           \At 15 the WF is killed to simulate a shutdown\n"
  test 25 30 20 15

  putStrLn "END"

-- /show

test stockdelay buydelay timereserve stopdelay = do
  let keyBook= "booktitle"
      rbook= getDBRef  keyBook

  enterStock stockdelay rbook

  buy buydelay rbook


  th <- forkIO $ exec "buyreserve" (buyReserve  timereserve) keyBook

  stopRestart stopdelay timereserve th

  threadDelay $ (buydelay- stopdelay+1) * 1000000
  putStrLn  "FINISHED"
  atomically $ delDBRef rbook
  putStrLn "----------------WORKFLOW HISTORY:--------------"
  h <- getHistory "buyreserve" keyBook
  putStrLn $ unlines h
  putStrLn "---------------END WORKFLOW HISTORY------------"
  delWF "buyreserve" keyBook




buyReserve timereserve  keyBook= do
    let rbook = getDBRef keyBook
    logWF $  "Reserve workflow start for: "++ keyBook
    t <- getTimeoutFlag timereserve  -- $ 5 * 24 * 60 * 60

    r <- WF.step . atomically $ (reserveIt rbook >> return True)
                      `orElse` (waitUntilSTM t >> return False)
    if not r
     then do
       logWF "reservation period ended, no stock available"
       return ()

     else do
       logWF "The book entered in stock, reserved "
       t <- getTimeoutFlag timereserve -- $ 5 * 24 *60 * 60
       r <- WF.step . atomically $ (waitUntilSTM t >> return False)
                          `orElse` (testBought rbook >> return True)

       if r
        then do
          logWF "Book was bought at this time"
        else do
          logWF "Reserved for a time, but reserve period ended"
          WF.step . atomically $ unreserveIt rbook
          return ()



reserveIt rbook = do
   mr <- readDBRef rbook
   case mr of
     Nothing -> retry
     Just (Book t s r) -> writeDBRef rbook $ Book t (s-1) (r+1)


unreserveIt rbook= do
   mr <- readDBRef rbook
   case mr of
     Nothing -> error "where is the book?"
     Just (Book t s r) -> writeDBRef rbook $ Book t (s+1) (r-1)

enterStock delay rbook= forkIO $ do
   liftIO $ threadDelay $ delay * 1000000
   putStrLn "ENTER STOCK"
   atomically $ writeDBRef rbook $ Book "booktitle" 5  0

buy delay rbook= forkIO $ do
  threadDelay $ delay * 1000000
  atomically $ do
   mr <- readDBRef rbook
   case mr of
     Nothing -> error "Not in stock"
     Just (Book t n n') ->
        if n' > 0 then writeDBRef rbook $ Book t n (n'-1)
                       !> "There is in Stock and reserved, BOUGHT"
        else if n > 0 then
                      writeDBRef rbook $ Book t (n-1) 0
                       !> "No reserved, but stock available, BOUGHT"
        else error "buy: neither stock nor reserve"

testBought rbook= do
    mr <- readDBRef rbook
    case mr of
       Nothing -> retry !>  ("testbought: the register does not exist: " ++ show rbook)
       Just (Book t stock reserve) ->
           case reserve  of
              0 -> return()
              n -> retry

stopRestart delay timereserve th=  do
    threadDelay $ delay * 1000000
    killThread th  !> "workflow KILLED"
    syncCache
    atomically flushAll
    restartWorkflows ( fromList [("buyreserve", buyReserve timereserve)] ) !> "workflow RESTARTED"

getHistory name x= liftIO $ do
   let wfname= keyWF name x
   let key= keyResource stat0{wfName=wfname}
   atomically $ flushKey key
   mh <- atomically . readDBRef . getDBRef $ key
   case mh of
      Nothing -> return ["No Log"]
      Just h  -> return  . catMaybes
                         . map eitherToMaybe
                         . map safeFromIDyn
                         $ versions h   :: IO [String]
   where
   eitherToMaybe (Right r)= Just r
   eitherToMaybe (Left _) = Nothing


