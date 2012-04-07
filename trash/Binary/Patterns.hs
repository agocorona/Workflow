{-# LANGUAGE DeriveDataTypeable, FlexibleContexts, ScopedTypeVariables, CPP #-}
{-# OPTIONS -IControl/Workflow       #-}

{- | This module contains monadic combinators that express
some workflow patterns.
see the docAprobal.hs example included in the package

This version uses Data.Binary serialization.
Here  the constraint `DynSerializer w r a` is equivalent to `Data.Binary a`.

EXAMPLE:

This fragment below describes the approbal procedure of a document.
First the document reference is sent to a list of bosses trough a queue.
ithey return a boolean in a  return queue ( askUser)
the booleans are summed up according with a monoid instance (sumUp)

if the resullt is false, the correctWF workflow is executed
If the result is True, the pipeline continues to the next stage  (checkValidated)

the next stage is the same process with a new list of users (superbosses).
This time, there is a timeout of 7 days. the result of the users that voted is summed
up according with the same monoid instance

if the result is true the document is added to the persistent list of approbed documents
if the result is false, the document is added to the persistent list of rejectec documents (checlkValidated1)


@docApprobal :: Document -> Workflow IO ()
docApprobal doc =  `getWFRef` \>>= docApprobal1


docApprobal1 rdoc=
    return True \>>=
    log \"requesting approbal from bosses\" \>>=
    `sumUp` 0 (map (askUser doc rdoc) bosses)  \>>=
    checkValidated \>>=
    log \"requesting approbal from superbosses or timeout\"  \>>=
    `sumUp` (7*60*60*24) (map(askUser doc rdoc) superbosses) \>>=
    checkValidated1


askUser _ _ user False = return False
askUser doc rdoc user  True =  do
      `step` $ `push` (quser user) rdoc
      `logWF` (\"wait for any response from the user: \" ++ user)
      `step` . `pop` $ qdocApprobal (title doc)

log txt x = `logWF` txt >> return x

checkValidated :: Bool -> `Workflow` IO Bool
checkValidated  val =
      case val of
        False -> correctWF (title doc) rdoc >> return False
        _     -> return True


checkValidated1 :: Bool -> Workflow IO ()
checkValidated1 val = step $ do
      case  val of
        False -> `push` qrejected doc
        _     -> `push` qapproved doc
      mapM (\u ->deleteFromQueue (quser u) rdoc) superbosses@


-}

module Control.Workflow.Binary.Patterns(
-- * Low level combinators
split, merge, select,
-- * High level conbinators
vote, sumUp, Select(..))
 where
import Control.Concurrent.STM
import Data.Monoid
import Control.Concurrent.MonadIO
import qualified Control.Monad.CatchIO as CMC
import Control.Exception(SomeException)
import Control.Workflow.Binary
import Prelude hiding (catch)
import Control.Monad(when)
import Control.Exception.Extensible(Exception)
import Data.RefSerialize
--import Debug.Trace

import Control.Workflow.Binary
import Control.Workflow.Stat(keyWF)
import Data.Typeable

import Data.Binary

instance Binary Select where
  put Select=  put (1 :: Int)
  put Discard= put (2 :: Int)
  put FinishDiscard = put (3 :: Int)
  put FinishSelect = put (4 :: Int)

  get= do
    n <- get :: Get Int
    case n of
      1 -> return Select
      2 -> return Discard
      3 -> return FinishDiscard
      4 -> return FinishSelect


#include "Patterns.inc.hs"
