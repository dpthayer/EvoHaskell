{-# LANGUAGE ForeignFunctionInterface,TypeSynonymInstances,FlexibleInstances  #-}
module Phylo.NLOpt where --(bobyqa,cobyla,mma,slsqp,newton,var1,var2,lbfgs,sbplx,neldermead,praxis,newuoa) where

import Data.Maybe (fromMaybe)
import Foreign
import Foreign.C
import Foreign.C.Types
import Foreign.Ptr (Ptr, FunPtr, freeHaskellFunPtr)
import Control.Monad
import Debug.Trace
import Control.Applicative
import Data.Maybe

foreign import ccall safe "nlopt_c opt_bobyqa" 
        bobyqa_ :: CDouble -> Ptr CDouble -> Ptr CDouble -> CUInt -> FunPtr ((CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble)) -> Ptr CDouble -> Ptr CDouble -> CInt
foreign import ccall safe "nlopt_c opt_cobyla" 
        cobyla_ :: CDouble -> Ptr CDouble -> Ptr CDouble -> CUInt -> FunPtr ((CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble)) -> Ptr CDouble -> Ptr CDouble -> CInt
foreign import ccall safe "nlopt_c opt_mma"
        mma_ :: CDouble -> Ptr CDouble -> Ptr CDouble -> CUInt -> FunPtr ((CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble)) -> Ptr CDouble -> Ptr CDouble -> CInt
foreign import ccall safe "nlopt_c opt_slsqp"
        slsqp_ :: CDouble -> Ptr CDouble -> Ptr CDouble -> CUInt -> FunPtr ((CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble)) -> Ptr CDouble -> Ptr CDouble -> CInt
foreign import ccall safe "nlopt_c opt_newton"
        newton_ :: CDouble -> Ptr CDouble -> Ptr CDouble -> CUInt -> FunPtr ((CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble)) -> Ptr CDouble -> Ptr CDouble -> CInt
foreign import ccall safe "nlopt_c opt_var1"
        var1_ :: CDouble -> Ptr CDouble -> Ptr CDouble -> CUInt -> FunPtr ((CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble)) -> Ptr CDouble -> Ptr CDouble -> CInt
foreign import ccall safe "nlopt_c opt_var2"
        var2_ :: CDouble -> Ptr CDouble -> Ptr CDouble -> CUInt -> FunPtr ((CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble)) -> Ptr CDouble -> Ptr CDouble -> CInt
foreign import ccall safe "nlopt_c opt_lbfgs"
        lbfgs_ :: CDouble -> Ptr CDouble -> Ptr CDouble -> CUInt -> FunPtr ((CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble)) -> Ptr CDouble -> Ptr CDouble -> CInt
foreign import ccall safe "nlopt_c opt_sbplx"
        sbplx_ :: CDouble -> Ptr CDouble -> Ptr CDouble -> CUInt -> FunPtr ((CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble)) -> Ptr CDouble -> Ptr CDouble -> CInt
foreign import ccall safe "nlopt_c opt_neldermead"
        neldermead_ :: CDouble -> Ptr CDouble -> Ptr CDouble -> CUInt -> FunPtr ((CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble)) -> Ptr CDouble -> Ptr CDouble -> CInt
foreign import ccall safe "nlopt_c opt_neldermead"
        praxis_ :: CDouble -> Ptr CDouble -> Ptr CDouble -> CUInt -> FunPtr ((CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble)) -> Ptr CDouble -> Ptr CDouble -> CInt
foreign import ccall safe "nlopt_c opt_newuoa"
        newuoa_ :: CDouble -> Ptr CDouble -> Ptr CDouble -> CUInt -> FunPtr ((CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble)) -> Ptr CDouble -> Ptr CDouble -> CInt

foreign import ccall "wrapper"
        wrap :: (CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble) -> IO (FunPtr ((CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble)))

nlopt :: (CDouble -> Ptr CDouble -> Ptr CDouble -> CUInt -> FunPtr ((CUInt -> Ptr CDouble -> Ptr CDouble -> Ptr () -> IO CDouble)) -> Ptr CDouble -> Ptr CDouble -> CInt) -> NLOptMethod -- [Double] -> Double ->  [Double] -> ([Double] -> (Double,Maybe [Double])) -> [Maybe Double] -> [Maybe Double] -> IO ([Double],Int)


type NLOptMethod = [Double] -> Double ->  [Double] -> ([Double] -> (Double,Maybe [Double])) -> [Maybe Double] -> [Maybe Double] -> IO ([Double],Int) 
instance Show NLOptMethod where
        show _ = "NLOpt"

bobyqa = nlopt bobyqa_
cobyla = nlopt cobyla_
mma = nlopt mma_
slsqp = nlopt slsqp_
newton = nlopt newton_
var1 = nlopt var1_
var2 = nlopt var2_
lbfgs = nlopt lbfgs_
sbplx = nlopt sbplx_
neldermead = nlopt neldermead_
praxis = nlopt praxis_
newuoa = nlopt newuoa_

traceX a x = trace (show a ++ (show x)) x
traceXm a = liftM (traceX a)
nlopt met stepSize xtol params f lower upper = do lower' <- newArray $ map (realToFrac . fromMaybe (-1E100)) lower
                                                  upper' <- newArray $ map (realToFrac . fromMaybe 1E100) upper 
                                                  stepSize' <- newArray $ map realToFrac stepSize
                                                  let np = trace ("Start params " ++ (show params) ++ " np " ++ (show (length params))) $ length params
                                                  let f' a b c d = do (ans,deriv)<-(liftM (invert2 f)) (fmap (map realToFrac) $ peekArray np b)
                                                                      case c of 
                                                                            x | x==nullPtr -> return ()
                                                                            ptr -> pokeArray ptr $ map realToFrac $ fromJust deriv
                                                                      return $ realToFrac ans
                                                  f'' <- wrap f'
                                                  startP <- newArray $ traceX ("realToFrac") $ map (realToFrac) params
                                                  let retCode = fromIntegral $ met (realToFrac xtol) stepSize' startP (fromIntegral np) f'' lower' upper' 
                                                  ans <- seq retCode $ fmap (map realToFrac) $ peekArray np startP
                                                  freeHaskellFunPtr f''
                                                  return (ans,retCode)

                                                                                                                                                              
-- | invert a function                                                                                                                                        
invert f = (*(-1)). f                                                                                                                                         
-- | invert both a function and a set of gradient                                                                                                             
invert2 f x = case (f x) of                                                                                                                                   
                (a,Just b)->(a*(-1),Just $ map (*(-1)) b)                                                                                                     
                (a,Nothing)->(a*(-1),Nothing)                                                                                                                 
                                                         
