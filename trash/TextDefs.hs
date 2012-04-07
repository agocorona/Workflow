{-# LANGUAGE

              MultiParamTypeClasses
            , FlexibleInstances
            , UndecidableInstances
            , TypeSynonymInstances


          #-}
module Control.Workflow.TextDefs where
import Control.Workflow.IDynamic
import Data.RefSerialize
import Data.RefSerialize
import System.IO.Unsafe
import Data.TCache.DefaultPersistence(Indexable(..))
import Data.IORef
import Unsafe.Coerce
import  Data.ByteString.Lazy.Char8 as B hiding (index)
import Control.Workflow.Stat
import Data.Map as M
import Control.Concurrent
import Data.TCache

