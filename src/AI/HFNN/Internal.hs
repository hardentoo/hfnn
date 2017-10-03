{-# LANGUAGE RankNTypes #-}
module AI.HFNN.Internal (
  WeightSelector,
  Layer,
  bias
 ) where

import Data.Semigroup
import Data.Word
import Foreign.Ptr
import Data.Array.Storable
import Foreign.Storable
import System.IO.Unsafe

import AI.HFNN.Activation

-- | Represents the relationship between a linear array of doubles and a
-- particular weight matrix. Phantom type to ensure only directed acyclic
-- graphs are created.
newtype WeightSelector s = WS IWeightSelector

data IWeightSelector = IWeightSelector {
  weightsInputs :: Int,
  weightsOutputs :: Int,
  getWeight :: (Int -> IO Double) -> Int -> Int -> IO Double,
  updateWeight :: (Int -> Double -> IO ()) -> Int -> Int -> Double -> IO ()
 }

-- | Represents a set of neurons which take inputs from a common set of parents.
-- Phantom type to ensure directed acyclic graphs are generated, and that
-- no arrays are indexed out of bounds.
newtype Layer s = Layer ILayer

data ILayer = ILayer Int Int

-- | Bias node: value is always 1.
bias :: forall s . Layer s
bias = Layer (ILayer 0 0)

-- Quick and dirty tree list. Won't bother balancing because we only need
-- to build and traverse: no need to lookup by index.
data CatTree a =
  Run !Word a |
  CatNode !Word (CatTree a) (CatTree a) |
  CatNil

catTreeSize (Run s _) = s
catTreeSize (CatNode s _ _) = s
catTreeSize CatNil = 0

instance Semigroup (CatTree a) where
  CatNil <> b = b
  a <> CatNil = a
  a <> b = CatNode (catTreeSize a + catTreeSize b) a b

instance Monoid (CatTree a) where
  mappend = (<>)
  mempty = CatNil

instance Functor CatTree where
  fmap f = go where
    go (Run l a) = Run l (f a)
    go (CatNode s a b) = CatNode s (go a) (go b)
    go CatNil = CatNil

instance Foldable CatTree where
  foldMap f = go where
    go (Run l a) = mr l where
      t = f a
      mr 1 = t
      mr n = let
        (nl,m) = n `divMod` 2
        nr = nl + m
        in mappend (mr nl) (mr nr)
    go (CatNode _ a b) = mappend (go a) (go b)
    go CatNil = mempty

instance Traversable CatTree where
  sequenceA CatNil = pure CatNil
  sequenceA (CatNode s a b) = CatNode s <$> sequenceA a <*> sequenceA b
  sequenceA r@(Run 1 a) = Run 1 <$> a
  sequenceA r@(Run _ _) = sequenceA $ expandCT r

expandCT :: CatTree a -> CatTree a
expandCT (Run s0 a) = let
  e 0 = CatNil
  e 1 = Run 1 a
  e n = let
    n' = n `div` 2
    in CatNode n (e n') (e (n - n'))
  in e s0
expandCT (CatNode s a b) = CatNode s (expandCT a) (expandCT b)
expandCT CatNil = CatNil

splitCT :: CatTree a -> Word -> (CatTree a, CatTree a)
splitCT CatNil _ = (CatNil, CatNil)
splitCT r 0 = (CatNil, r)
splitCT r@(Run n a) s = if n <= s
  then (r,CatNil)
  else (Run s a, Run (s - n) a)
splitCT r@(CatNode n a b) s = if n <= s
  then (r,CatNil)
  else case catTreeSize a `compare` s of
    EQ -> (a, b)
    LT -> let
      (l,b') = splitCT b (s - catTreeSize a)
      in (a <> l, b')
    GT -> let
      (a',l) = splitCT a s
      in (a', l <> b)

instance Applicative CatTree where
  pure = Run 1
  CatNil <*> _ = CatNil
  _ <*> CatNil = CatNil
  r@(Run lf f) <*> a' = let
    rt = fmap f a'
    go (CatNode _ a b) = go a <> go b
    go (Run 1 _) = rt
    go r@(Run _ _) = go (expandCT r)
    go CatNil = CatNil
    in go r
  (CatNode _ a b) <*> r = (a <*> r) <> (b <*> r)

instance Monad CatTree where
  return = pure
  fail = const CatNil
  r@(Run _ a) >>= f = let
    rt = f a
    go (CatNode _ a b) = go a <> go b
    go (Run 1 _) = rt
    go r@(Run _ _) = go (expandCT r)
    go CatNil = CatNil
    in go r
  (CatNode _ a b) >>= f = (a >>= f) <> (b >>= f)
  CatNil >>= _ = CatNil

reverseCT :: CatTree a -> CatTree a
reverseCT r@(Run _ _) = r
reverseCT (CatNode l a b) = CatNode l (reverseCT b) (reverseCT a)
