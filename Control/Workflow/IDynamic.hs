{-# OPTIONS -XExistentialQuantification
            -XOverlappingInstances
            -XUndecidableInstances
            -XScopedTypeVariables
            -XDeriveDataTypeable
            -XTypeSynonymInstances
            -XIncoherentInstances
            -XOverloadedStrings
            -XMultiParamTypeClasses
            -XFunctionalDependencies
            -XFlexibleInstances #-}
{- |
IDynamic is a indexable and serializable version of Dynamic. (See @Data.Dynamic@). It is used as containers of objects
in the cache so any new datatype can be incrementally stored without recompilation.
IDimamic provices methods for safe casting,  besides serializaton, deserialirezation and retrieval by key.
-}
module Control.Workflow.IDynamic where
import Data.Typeable
import Unsafe.Coerce
import System.IO.Unsafe
import Data.TCache
import Data.TCache.DefaultPersistence
import Data.RefSerialize


import Data.ByteString.Lazy.Char8 as B

import Data.Word
import Numeric (showHex, readHex)
import Control.Exception(handle, SomeException, ErrorCall)
import Control.Monad(replicateM)
import Data.Word
import Control.Concurrent.MVar
import Data.IORef
import Data.Map as M(empty)
import Data.RefSerialize
import Data.HashTable as HT




data IDynamic  =  IDyn  (IORef IDynType)

data IDynType= forall a w r.(Typeable a, Serialize a)
               => DRight  !a
               |  DLeft  !(ByteString ,(Context, ByteString))


               deriving Typeable

{-
class (Monad writerm , Monad readerm)
       => Serializer writerm readerm   a
       | a -> writerm readerm   where
  serial     :: a -> writerm ()
  deserial   :: readerm a
  fromString :: ByteString -> a
  toString :: a -> ByteString

  serialM   :: a -> writerm ByteString
  serialM = return . toString

  fromDynData :: ByteString ->(Context, ByteString) ->  a
  fromDynData s _= fromString s

  dGetContext :: a -> readerm (Context, ByteString)
  dGetContext _ = return (M.empty,"")


class (Serializer w r a, Serializer w' r' b) => TwoSerializer w r w' r' a b


instance (Serializer w r a, Serializer w' r' b) => TwoSerializer w r w' r' a b
-}
{-
  symbols :: (Show symbolType, Eq symbolType)=> [symbolType]
  symbols= []


instance  (Serializer m n s Int, Serializer m n s a) => Serializer m n s [a] where
   serial xs= serial (Prelude.length xs) >> mapM_ serial xs
   deserial = do
     n <- deserial
     replicateM n deserial

instance Binary a => Serializer PutM Get a where
  serial = put
  deserial = get




choices :: (Serializer writerm readerm c symbolType
           , Serializer writerm readerm symbolType a)
           =>[(symbolType, readerm a)] -> readerm a
choices l=  do
  n <- deserial
  case lookup n l of
    Just f -> f
    Nothing -> error $ "case "++ show n ++ "not in choice"

-}

errorfied str str2= error $ str ++ ": IDynamic object not reified: "++ str2



dynPrefix= "Dyn"
dynPrefixSp= append  (pack dynPrefix) " "

{-
instance Serialize IDynamic where
   showp (IDyn x)= do
      showpx <- showp x
      len <- showpText . fromIntegral $ B.length showpx
      return $ dynPrefixSp `append` len `append` " " `append` showpx

   showp (IDyns showpx)= do
      len <- showpText  $  B.length showpx
      return $ dynPrefixSp `append` len `append` " " `append` showpx
   readp = do
      symbol dynPrefix
      n <- readpText
      s <- takep n
      c <- getContext
      return $ IDyns $ s `append` "*where*" `append` c


instance Binary IDynamic where
   put (IDyn x) =  put $! toString x
   put (IDyns s) =   put s

   get =  do
     s <- get
     return $ IDyns  s



instance (Serializer w r  ByteString) => Serializer w r  IDynamic where
   serial (IDyn r)=
        let t= unsafePerformIO $ readIORef r
        in case t of

         DRight x -> do
           s <- unsafeCoerce $ serialM x  -- thatś why Binary and Text versions fo workflow can not be mixed
           serial $! (s :: ByteString)
         DLeft (s , _) -> serial s

   deserial =  do
       s <- deserial
       c <- dGetContext (undefined :: IDynamic)
       return $ IDyn  $! ref s c
       where
       ref s c= unsafePerformIO . newIORef $ DLeft (s,c)

   toString (IDyn r)=
       let t= unsafePerformIO $ readIORef r
       in case t of
          DRight x -> toString x
          DLeft (s, _) ->  s

   fromString s= IDyn . unsafePerformIO . newIORef $ DLeft (s,(M.empty,""))

-}



instance Serialize IDynamic where

   showp (IDyn t)=
    case unsafePerformIO $ readIORef t of
     DRight x -> do
          insertString $ pack dynPrefix
          showpx <-   showps x
          showpText . fromIntegral $ B.length showpx
          insertString showpx




     DLeft (showpx,_) -> do  --  error $ "IDynamic not reified :: "++  unpack showpx
        insertString  $ pack dynPrefix
        showpText 0

   readp = do
      symbol dynPrefix
      n <- readpText
      s <- takep n


      c <- getContext
      return . IDyn . unsafePerformIO . newIORef $ DLeft ( s, c)
      <?> "IDynamic"



instance Show  IDynamic where
 show (IDyn r) =
    let t= unsafePerformIO $ readIORef r
    in case t of
      DRight x -> "IDyn " ++  ( unpack . runW $ showp  x)  ++ ")"   
      DLeft (s, _) ->  "IDyn " ++ unpack s





toIDyn x= IDyn . unsafePerformIO . newIORef $ DRight x

 
fromIDyn :: (Typeable a , Serialize a)=> IDynamic -> a
fromIDyn x=r where
  r = case safeFromIDyn x of
          Nothing -> error $ "fromIDyn: casting failure for data "
                     ++ show x ++ " to type: "
                     ++ (show $ typeOf r)
          Just v -> v


safeFromIDyn :: (Typeable a, Serialize a) => IDynamic -> Maybe a       
safeFromIDyn (IDyn r)=unsafePerformIO $ do
  t<-  readIORef r
  case t of
   DRight x ->  return $ cast x

   DLeft (str, c) ->
    handle (\(e :: SomeException) ->  return Nothing) $  -- !> ("safeFromIDyn : "++ show e)) $
        do
          let v= runRC  c readp str
          writeIORef r $! DRight v -- !> ("***reified "++ unpack str)
          return $! Just v -- !>  ("*** end reified " ++ unpack str)


--main= print (safeFromIDyn $ IDyn $ unsafePerformIO $ newIORef $ DLeft $ (pack "1", (unsafePerformIO $ HT.new (==) HT.hashInt, pack "")) :: Maybe Int)


