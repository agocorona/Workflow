-----------------------------------------------------------------------------
--
-- Module      :  Control.Workflow.GenSerializer
-- Copyright   :
-- License     :  BSD3
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :  experimental
-- Portability :
--
-----------------------------------------------------------------------------

{-# OPTIONS
             -XMultiParamTypeClasses
             -XFunctionalDependencies
             -XFlexibleContexts
             -XFlexibleInstances
             -XUndecidableInstances
             -XScopedTypeVariables
 #-}

{- |
 This module includes the definition of a generic (de)serializer. This is used as a class constraints
 for the Workflow methods.

 Data.RefSerialize (defined in "Control.Workflow.Text.TextDefs") and Data.Binary ("Control.Workflow.Binary.BinDefs")
 are particular instances of thiis generic serializer.
-}

module Control.Workflow.GenSerializer where
import Data.ByteString.Lazy.Char8 as B
import Data.RefSerialize(Context)
import Data.Map as M
import Control.Concurrent
import System.IO.Unsafe

class  (Monad writerm, Monad readerm)
       => Serializer writerm readerm a | a -> writerm readerm where
  serial     ::  a -> writerm ()
  deserial   ::  readerm  a




class (DynSerializer w r a, DynSerializer w r b) => TwoSerializer w r a b


instance (DynSerializer w r a, DynSerializer w r b) => TwoSerializer w r a b

class (DynSerializer w r a, DynSerializer w r b,DynSerializer w r c) => ThreeSerializer w r a b c


instance (DynSerializer w r a, DynSerializer w r b, DynSerializer w r c) => ThreeSerializer w r a b c


class  (Monad writerm
       ,Monad readerm)
       => RunSerializer writerm readerm
       | writerm -> readerm
       , readerm -> writerm
       where
  runSerial   ::  writerm () -> ByteString
  runDeserial ::  Serializer writerm readerm a => readerm  a  -> ByteString -> a

class (Serializer w r a, RunSerializer w r) => DynSerializer w r a | a -> w r where
  serialM   :: a -> w ByteString
  serialM  = return . runSerial . serial

  fromDynData :: ByteString ->(Context, ByteString) ->  a
  fromDynData s _= runDeserial deserial s
