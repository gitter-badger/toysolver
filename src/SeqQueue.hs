{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses #-}
module SeqQueue
  ( SeqQueue
  , NewFifo (..)
  , Enqueue (..)
  , Dequeue (..)
  , clear
  ) where

import Data.IORef
import Data.Queue
import Data.Foldable
import qualified Data.Sequence as Seq

newtype SeqQueue a = SeqQueue (IORef (Seq.Seq a))

instance NewFifo (SeqQueue a) IO where
  newFifo = do
    ref <- newIORef Seq.empty
    return (SeqQueue ref)

instance Enqueue (SeqQueue a) IO a where
  enqueue (SeqQueue ref) val = do
    modifyIORef ref (Seq.|> val)

instance Dequeue (SeqQueue a) IO a where
  dequeue (SeqQueue ref) = do
    s <- readIORef ref
    case Seq.viewl s of
      Seq.EmptyL -> return Nothing
      val Seq.:< s' -> do
        writeIORef ref s'
        return (Just val)

  dequeueBatch (SeqQueue ref) = do
    s <- readIORef ref
    writeIORef ref Seq.empty
    return (toList s)

clear :: SeqQueue a -> IO ()
clear (SeqQueue ref) = do
  writeIORef ref Seq.empty
