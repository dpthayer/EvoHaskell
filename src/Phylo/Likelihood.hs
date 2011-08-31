module Phylo.Likelihood where
import Phylo.Alignment
import Phylo.Tree
import Phylo.Matrix
import Phylo.Opt
import Numeric.LinearAlgebra ((<>),(<.>),scale,mul,constant,diag)
import Data.Packed.Matrix
import Data.Packed.Vector
import Data.List
import Data.Maybe
import Statistics.Math
import Numeric.GSL.Distribution.Continuous
import Numeric.GSL.Minimization
import Control.Exception as E
import Control.Parallel
import Control.Parallel.Strategies
import Debug.Trace
import Phylo.Data


-- |Combine two sets of partial likelihoods along two branches
combinePartial :: Matrix Double -> Matrix Double -> Matrix Double
combinePartial = mul 

-- |Combine two lists of partial likelihoods (for mixture models)
allCombine :: [Matrix Double] -> [Matrix Double] -> [Matrix Double]
allCombine (left:lefts) (right:rights) = (combinePartial left right):(allCombine lefts rights)
allCombine [] [] = []

rawPartialLikelihoodCalc :: Matrix Double -> Matrix Double -> Matrix Double
rawPartialLikelihoodCalc pT start = pT <> start

allPLC :: [Matrix Double] -> [Matrix Double] -> [Matrix Double]
allPLC (pT:pTs) (start:starts) = (rawPartialLikelihoodCalc pT start):(allPLC pTs starts)
allPLC [] [] = []


sumLikelihoods :: [Int] -> [Double] -> Double
sumLikelihoods counts likelihoods = foldr foldF 0 $ zip (map fromIntegral counts) likelihoods where
                                        foldF :: (Double,Double) -> Double -> Double 
                                        foldF (i,y) x = x + (i * (log y))
                                        

logLikelihoodModel :: DNode -> Double
logLikelihoodModel (DTree left middle right pLs pC priors pis) = sumLikelihoods pC likelihoods where
                                                                likelihoodss = map toList $ map (\(pi,pL) -> pi <> pL) $ zip pis pLs
                                                                likelihoods = map summarise (transpose likelihoodss) 
                                                                summarise lkl = sum $ zipWith (*) lkl priors
                                                                
logLikelihood = logLikelihoodModel

data PatternAlignment = PatternAlignment {names :: [String], seqs::[String], columns::[String], patterns::[String], counts::[Int]}

pAlignment (ListAlignment names seqs columns) = PatternAlignment names seqs columns patterns counts where
                                                   (patterns,counts) = unzip $ map (\x -> (head x,length x)) $ group $ sort columns

calcPL :: DNode -> DNode -> [Double] -> [BranchModel] -> [Matrix Double]
calcPL left right dist model = allPLC (map (\x-> x dist) model) $ allCombine (getPL left) (getPL right) 
calcLeafPL :: Matrix Double -> [Double] -> [BranchModel] -> [Matrix Double]
calcLeafPL tips dist model = map (\pT -> rawPartialLikelihoodCalc pT tips) $ (map (\x -> x dist) model)
calcRootPL left middle right = allCombine (getPL middle) $ allCombine (getPL left) (getPL right)


restructData (DLeaf name dist sequence partial _ _) model priors pi  = DLeaf name dist sequence partial model partial' where
                                                                               partial' = calcLeafPL partial dist model
restructData (DINode left right dist _ _ ) model priors pi= newleft `par` newright `par` DINode newleft newright dist model partial where
                                                            partial = calcPL newleft newright dist model
                                                            newleft = restructData left model priors pi
                                                            newright = restructData right model priors pi
restructData (DTree left middle right _ pc _ _ ) model priors pi = newleft `par` newright `par` newmiddle `par` DTree newleft newmiddle newright partial pc priors pi where 
                                            partial = calcRootPL newleft newmiddle newright
                                            newleft = restructData left model priors pi
                                            newright = restructData right model priors pi
                                            newmiddle = restructData middle model priors pi  

structDataN :: Int -> SeqDataType -> PatternAlignment -> Node -> NNode

structDataN hiddenClasses seqDataType pAln node = structDataN' hiddenClasses seqDataType pAln (transpose $ patterns pAln) node 
structDataN' hiddenClasses seqDataType (PatternAlignment names seqs columns patterns counts) transPat (Leaf name dist) = ans where
                                                                                                                          partial = getPartial hiddenClasses seqDataType sequence 
                                                                                                                          sequence = snd $ fromJust $ find (\(n,_) -> n==name) $ zip names transPat 
                                                                                                                          ans = NLeaf name [dist] sequence partial 


structDataN' hiddenClasses seqDataType pA transPat (INode c1 c2 dist) = left `par` right `par` NINode left right [dist] where
                                                                              left = structDataN' hiddenClasses seqDataType pA transPat c1
                                                                              right = structDataN' hiddenClasses seqDataType pA transPat c2

structDataN' hiddenClasses seqDataType pA transPat (Tree (INode l r dist) c2 ) = left `par` middle `par` right `par` NTree left middle right $ counts pA where
                                                                                  left = structDataN' hiddenClasses seqDataType pA transPat l
                                                                                  right = structDataN' hiddenClasses seqDataType pA transPat r
                                                                                  middle = structDataN' hiddenClasses seqDataType pA transPat $ addDist dist c2
                                                                                  addDist d (Leaf name dist) = Leaf name (dist+d)
                                                                                  addDist d (INode l r dist) = INode l r (dist+d)

structDataN' hiddenClasses seqDataType pA transPat (Tree c2 (INode l r dist)) = structDataN' hiddenClasses seqDataType pA transPat (Tree (INode l r dist) c2)

structDataN' hiddenClasses seqDataType pA transPat (Tree (Leaf name dist) (Leaf name2 dist2))  = error "Can't handle tree with only 2 leaves"


structData hiddenClasses seqDataType pAln model transPat node = addModel (structDataN hiddenClasses seqDataType pAln node) model 



addModelNNode :: NNode -> [BranchModel] -> [Double] -> [Vector Double] -> DNode
addModelNNode (NLeaf name dist sequence partial) model _ _  = DLeaf name dist sequence partial model partial' where
                                                                                              partial' = calcLeafPL partial dist model

addModelNNode (NINode c1 c2 dist) model priors pi =  left `par` right `par` DINode left right dist model myPL where
                                                  left = addModelNNode c1 model priors pi
                                                  right = addModelNNode c2 model priors pi
                                                  myPL = calcPL left right dist model 
                                                                            
addModelNNode (NTree c1 c2 c3 pat) model priors pi = left `par` right `par` middle `par` DTree left middle right myPL pat priors pi where
                                  left = addModelNNode c1 model priors pi
                                  middle = addModelNNode c2 model priors pi
                                  right= addModelNNode c3 model priors pi
                                  myPL = calcRootPL left middle right

data SeqDataType = AminoAcid | Nucleotide
getPartial :: Int -> SeqDataType -> String -> Matrix Double
getPartial a b c = trans $ fromRows $ getPartial' a b c
getPartial' :: Int -> SeqDataType -> String -> [Vector Double]
getPartial' _ _ [] = []
getPartial' classes AminoAcid (x:xs) = (aaPartial classes x):(getPartial' classes AminoAcid xs)
getPartial' classes Nucleotide (x:xs) = error "Nucleotides unimplemented"

aaOrder = ['A','R','N','D','C','Q','E','G','H','I','L','K','M','F','P','S','T','W','Y','V']
aaPartial classes x | isGapChar x = buildVector (20*classes) (\i->1.0) 
                    | otherwise = case findIndex (==x) aaOrder of 
                                       Just index -> buildVector (20*classes) (\i -> if i`mod`20==index then 1.0 else 0.0) where
                                       Nothing -> error $ "character " ++ [x] ++ "is not an amino acid or gap"

                                 


quickGamma' numCat tree priors pi s aln alpha = logLikelihood dataTree  where
                                                dataTree = structData 1 AminoAcid pAln (map (\r->scaledpT r eigenS) rates) transpats tree priors (repeat pi)
                                                rates = gamma numCat alpha
                                                transpats = transpose $ patterns pAln
                                                eigenS = quickEigen pi s
                                                pAln = pAlignment aln
                                                patcounts = counts pAln
                                                
                                                        
quickEigen pi s = eigQ (normQ (makeQ s pi) pi) pi

standardpT = scaledpT 1.0
scaledpT scale eigenS params = pT eigenS $ (head params) * scale


optGammaF :: Int -> ListAlignment -> Node -> Vector Double -> Matrix Double -> (Double -> Double)
optGammaF numCat aln tree pi s = quickGamma' numCat tree priors pi s aln where
                                                priors = take numCat $ repeat (1.0/(fromIntegral numCat))


--flatFullPi numCat pi = Data.Packed.Vector.mapVector (/(fromIntegral numCat)) $ Data.Packed.Vector.join $replicate numCat pi
flatFullPi numCat pi = makeFullPi (replicate numCat (1.0/(fromIntegral numCat))) pi
makeFullPi priors pi = Data.Packed.Vector.join $ map (\p->Data.Packed.Vector.mapVector (*p) pi) priors
flatPriors numCat = replicate numCat (1.0/ (fromIntegral numCat))

gammaMix numCat alpha (u,lambda,u') = map (\s -> (u,scale s lambda,u')) scales where
                           scales = gamma numCat alpha

gamma :: Int -> Double -> [Double]
gamma numCat shape | shape > 50000.0 = gamma numCat 50000.0 --work around gsl convergence errors (who wants >100 in the gamma dist anyway?)
                   | otherwise       = map rK' [0..(numCat-1)] where
                        alpha = shape
                        beta = shape
                        factor = alpha/beta*(fromIntegral numCat)

                        freqK = map freqKf [0..(numCat-1)]
                        freqKf i = incompleteGamma (alpha + 1.0) (beta * (gammaInvCDF (((fromIntegral i)+1.0)/(fromIntegral numCat))))

                        rK' 0 = (head freqK) * factor
                        rK' n | n < numCat = ((freqK!!n) - (freqK!!(n-1))) * factor
                              | otherwise = factor * (1.0-(freqK!!(numCat-2)))
                        gammaInvCDF p = (density_1p ChiSq UppInv (2.0*alpha) (1.0-p)) / (2.0*beta) -- (UppInv mysteriously has more stable convergence)


type BranchModel = [Double] -> Matrix Double
type OptModel = DNode -> [Double] -> Double
data DNode = DLeaf {dName :: String,dDistance :: [Double],sequence::String,tipLikelihoods::Matrix Double,p::([[Double] -> Matrix Double]),partialLikelihoods::[Matrix Double]} |
        DINode DNode DNode [Double] ([[Double] -> Matrix Double]) [Matrix Double] | 
        DTree DNode DNode DNode [Matrix Double] [Int] [Double] [(Vector Double)]

data NNode = NLeaf String [Double] String (Matrix Double) | NINode NNode NNode [Double] | NTree NNode NNode NNode [Int]
data DataModel = DataModel {dTree::DNode, patterncounts::[Int], priors::[Double], pis::[Vector Double]}

instance Show DNode where
        show (DTree l m r _ _ _ _) = "("++(show l)++","++(show m)++","++(show r)++");"
        show (DINode l r [d] _ _) = "(" ++ (show l)++","++(show r)++"):"++(show d)
        show (DINode l r d _ _) = "(" ++ (show l)++","++(show r)++"):"++(show d)
        show (DLeaf name [d] _ _ _ _) = name++":"++(show d)
        show (DLeaf name d _ _ _ _) = name++":"++(show d)


class AddTree a where
        addModel :: (AddTree a) => a -> [BranchModel] -> [Double] -> [Vector Double] -> DNode
        addModelFx :: (AddTree a) => a -> ([BranchModel],[Vector Double]) -> [Double] -> DNode
        addModelFx t (bm,pi) prior = addModel t bm prior pi
instance AddTree NNode where
        addModel w x y z = ans2 where
                       ans = addModelNNode w x y z
                       ans2 = seq (getPL ans) ans
instance AddTree DNode where
        addModel w x y z = ans2 where 
                           ans = restructData w x y z
                           ans2 = seq (getPL ans) ans

getPL (DLeaf _ _ _ _ _ lkl) = lkl
getPL (DINode _ _ _ _ lkl) = lkl
getPL (DTree _ _ _ lkl _ _ _) = lkl

goLeft (DTree (DINode l r dist model pL) middle right _ pC priors pi)  = DTree l r r' rootpL pC priors pi where
        rootpL = calcRootPL l r r'
        r' = DINode middle right dist model pL' 
        pL' = calcPL middle right dist model

goRight (DTree left middle (DINode l r dist model pL) _ pC priors pi) = DTree l' l r rootpL pC priors pi where
        rootpL = calcRootPL l' l r
        l' = DINode left middle dist model pL'
        pL' = calcPL left middle dist model

canGoLeft (DTree (DINode _ _ _ _ _) _ _ _ _ _ _ ) = True
canGoLeft _ = False

optBLD = optBLDx optLeftBL
optBLD0 = optBLDx (optLeftBLx 0)

optBLDx f tree = t3 where
        t1 = swapLeftMiddle $ f $ if (canGoLeft tree) then optBL' f (goLeft tree) else tree
        t2 = swapLeftRight $ f $ swapLeftMiddle $ if (canGoLeft t1) then goRight $ optBL' f (goLeft t1) else t1
        t3 = swapLeftRight $ f $ if (canGoLeft t2) then goRight $ optBL' f (goLeft t2) else t2

optBL' f tree = ans where
        leftOptd = if (canGoLeft tree) then goRight $ optBL' f (goLeft tree) else tree
        ansL = swapLeftMiddle $ f leftOptd
        midOptd = if (canGoLeft ansL) then goRight $ optBL' f (goLeft ansL) else ansL
        ans = swapLeftMiddle $ f midOptd


descendents (DTree l m r _ _ _ _) = (descendents l) ++ (descendents m ) ++ (descendents r)
descendents (DLeaf name _ _ _ _ _) = [name] 
descendents (DINode l r _ _ _) = (descendents l) ++ (descendents r)

--setLeftBL (DTree l m r _ _ _ _ ) x | trace ((show x ) ++ " (" ++ (descendents l) ++ " : " ++ (descendents m) ++ " : " ++ (descendents r) ++ ")") False = undefined

setLeftBL (DTree (DLeaf name dist seq tip model _) m r _ pC priors pi) x = (DTree newleft m r pl' pC priors pi) where
        partial' = calcLeafPL tip x model
        newleft = DLeaf name x seq tip model partial'
        pl' = calcRootPL newleft m r 


setLeftBL (DTree (DINode l1 r1 dist model _) m r _ pC priors pi) x = (DTree newleft m r pl' pC priors pi) where
        partial' = calcPL l1 r1 x model
        newleft = DINode l1 r1 x model partial'
        pl' = calcRootPL newleft m r 

optLeftBL tree  = traceShow ("OptBL " ++ (show best) ++ "->" ++ (show $ logLikelihood $ setLeftBL tree best)) $ setLeftBL tree best where
                        (DTree l _ _ _ _ _ _ ) = tree
                        best = case l of 
                                (DINode _ _ [param] _ _) -> (goldenSection 0.01 0.001 10.0 (invert $ (\x -> logLikelihood $ setLeftBL tree [x]))) : []
                                (DLeaf _ [param] _ _ _ _) -> (goldenSection 0.01 0.001 10.0 (invert $ (\x -> logLikelihood $ setLeftBL tree [x]))) : []
                                (DLeaf _ params _ _ _ _) -> fst $ maximize NMSimplex2 1E-4 1000 (map (\i->0.05) params) (boundedBLfunc (\x -> logLikelihood $ setLeftBL tree x)) params    
                                (DINode _ _ params _ _) -> fst $ maximize NMSimplex2 1E-4 1000 (map (\i->0.05) params) (boundedBLfunc (\x -> logLikelihood $ setLeftBL tree x)) params    

getLeftBL (DTree (DINode _ _ x _ _) _ _ _ _ _ _) = x
getLeftBL (DTree (DLeaf _ x _ _ _ _) _ _ _ _ _ _) = x

optLeftBLx val tree  = traceShow ("OptBL " ++ (show startBL) ++ " -> " ++ (show best) ++ " -> " ++ (show $ logLikelihood $ setLeftBL tree best)) $ setLeftBL tree best where
                                startBL = getLeftBL tree
                                b = goldenSection 0.01 0.001 10.0 (invert $ (\x -> logLikelihood $ setLeftBL tree (replace val [x] startBL)))
                                best = replace val [b] startBL


boundedBLfunc = boundedFunction (-1E20) (repeat $ Just 0.0) (repeat Nothing)

swapLeftMiddle (DTree l m r pL pC priors pi) = DTree m l r pL pC priors pi
swapLeftRight (DTree l m r pL pC priors pi) = DTree r m l pL pC priors pi


getSplits node = map invertSplit $ getSplits' node [] where
                        alldescendents = sort $ descendents node
                        invertSplit s = ((sort s), filter (\x -> x `elem` s) alldescendents) 

getSplits' (DTree l m r _ _ _ _ ) splits = (getSplits' l (getSplits' m (getSplits' r splits)))
getSplits' (DINode l r _ _ _ ) splits = (descendents l ++ descendents r):(getSplits' l (getSplits' r splits))
getSplits' (DLeaf name _ _ _ _ _) splits = [name]:splits

getBL node = concat $ getBL' node []

getBL' (DLeaf _ bl _ _ _ _) bls = bl : bls
getBL' (DINode l r bl _ _) bls = bl : (getBL' l (getBL' r bls))
getBL' (DTree l m r _ _ _ _ ) bls = (getBL' l (getBL' m (getBL' r bls)))

setBL :: [Double] -> DNode -> DNode 
setBL bls node = fst $ setBL' bls node
setBL' x = setBLX' 0 [x]

setBLX' i bls (DTree l m r pl pC priors pi) = ((DTree left middle right partial pC priors pi), remainder3) where
                        (left,remainder) = setBLX' i bls l
                        (middle,remainder2) = setBLX' i remainder m
                        (right,remainder3) = setBLX' i remainder2 r
                        partial = calcRootPL left middle right

setBLX' i (bl2:bls) (DINode l r blstart mats pl) = ((DINode left right newbl mats partial), remainder2) where
                             (left,remainder) = setBLX' i bls l
                             (right,remainder2) = setBLX' i remainder r
                             partial = calcPL left right (newbl) mats
                             newbl = replace i bl2 blstart

setBLX' i (bl2:bls) (DLeaf a (blstart) b tips model _) = ((DLeaf a newbl b tips model pl),bls) where
                                      pl = calcLeafPL tips newbl model 
                                      newbl = replace i bl2 blstart

setBLX' _ [] _ = error "Insuffiencent branch lengths specified"


replace 0 [x] (s:ss) = (x:ss)
replace i x start =  (take (i) start) ++ x ++ (drop (i + (length x)) start)

listpartition (c:counts) start ans = listpartition counts b (a:ans) where
                                 (a,b) = splitAt c start
listpartition [] [] ans = reverse ans
listpartition [] start ans = listpartition [] [] (start:ans)


setBLflat i node = setBLflat' i node $ map (\x -> (length x) - i) (getBL' node [])
setBLflat' i node counts bls = setBLX' i (listpartition counts bls []) node
                        

zeroQMat size = diag $ constant 0.0 size

qdLkl numCat priors dataType aln tree modelF params = logLikelihood $ addModelFx (structDataN numCat dataType (pAlignment aln) tree) (modelF params) priors

type ModelF = [Double] -> ([BranchModel],[Vector Double])
basicModel :: Matrix Double -> Vector Double -> ModelF
basicModel s pi _ = ([model],[pi]) where
                    model = standardpT $ quickEigen pi s

quickLkl aln tree pi s = qdLkl 1 [1.0] AminoAcid aln tree (basicModel s pi) []
quickGamma numCat alpha aln tree pi s = qdLkl 1 (flatPriors numCat) AminoAcid aln tree (gammaModel numCat s pi) [alpha]

gammaModel numCat s pi (alpha:xs) = (models,replicate numCat pi) where
                                models  = map (\r -> scaledpT r eigenS) $ gamma numCat alpha
                                eigenS  = quickEigen pi s

thmmModel numCat s pi [priorZero,alpha,sigma] = ([thmm numCat pi s priors alpha sigma],[fullPi]) where
                        priors = priorZero : (replicate (numCat -1) ((1.0-priorZero)/(fromIntegral (numCat-1))) )
                        fullPi = makeFullPi priors pi

thmmPerBranchModel numCat s pi [priorZero,alpha] = ([thmmPerBranch numCat pi s priors alpha],[fullPi]) where 
                        priors = priorZero : (replicate (numCat -1) ((1.0-priorZero)/(fromIntegral (numCat-1))) )
                        fullPi = makeFullPi priors pi

quickThmm numCat aln tree pi s [priorZero,alpha,sigma] = qdLkl numCat [1.0] AminoAcid aln tree (thmmModel numCat s pi) [priorZero,alpha,sigma] 
                                                        
thmm :: Int -> Vector Double -> Matrix Double -> [Double] -> Double -> Double -> BranchModel
thmm numCat pi s priors alpha sigma = standardpT $ eigQ (fixDiag $ fromBlocks subMats) fullPi where
                                        qMats = (zeroQMat (rows s)) : (map (\(i,mat) -> setRate i mat pi) $ zip (gamma (numCat -1) alpha) $ replicate numCat $ makeQ s pi)
                                        subMats = map (\(i,mat) -> getRow i mat) $ zip [0..] qMats
                                        getRow i mat = map (kk' mat i) [0..(numCat-1)] 
                                        fullPi = makeFullPi priors pi
                                        size = cols s
                                        kk' mat i j | i==j = mat
                                                    | otherwise = diagRect 0.0 (mapVector ((priors !! j) * sigma * ) pi) size size

thmmPerBranch :: Int -> Vector Double -> Matrix Double -> [Double] -> Double -> [Double] -> Matrix Double
thmmPerBranch numCat pi s priors alpha [branchLength,sigma] = thmm numCat pi s priors alpha sigma [branchLength]
thmmPerBranch numCat pi s priors alpha paramList | trace ("thmmpb " ++ (show paramList)) False = undefined




loggedFunc :: (Show a) => (a -> Double) -> (a -> Double)
loggedFunc f = f2 where
               f2 x = ans3 where
                      ans3 | trace (show x) True = ans2
                      ans2 | trace ((show x) ++ " -> " ++ (show ans)) True = ans
                      ans = f x
                    
maximize method pre maxiter size f params = minimize method pre maxiter size (invert f) params where

invert f = (*(-1)). f


optBL :: (AddTree t) => ModelF -> t -> [Double] -> [Double] -> Double -> DNode
optBL model t' params priors cutoff = traceShow optTree optTree where
        tree  = addModelFx t' (model params) priors
        optTree = optBLD $ optBLD tree

optBLx :: (AddTree t) => Int ->  ModelF -> t -> [Double] -> [Double] -> Double -> DNode
optBLx val model t' params priors cutoff = traceShow optTree optTree where
                tree  = addModelFx t' (model params) priors
                optTree = optBLD $ optBLD tree
 
optParams :: (AddTree t) => ModelF -> t -> [Double] -> [Double] -> [Maybe Double] -> [Maybe Double] -> Double -> [Double]
optParams model t' params priors lower upper cutoff = bestParams where
        tree = addModelFx t' (model params) priors
        optParamsFunc = loggedFunc . boundedFunction (-1E20) lower upper . rawOptParamsFunc       
        rawOptParamsFunc t params = logLikelihood $ addModelFx t (model params) priors                                                                                    
        (bestParams,_) = maximize NMSimplex2 1E-4 100000 (map (\i->0.1) params) (optParamsFunc tree) params    

optBSParams ::  ModelF -> DNode -> [Double] -> Int -> [Int] -> [Double] -> [Maybe Double] -> [Maybe Double] -> Double -> (DNode,[Double])
optBSParams | trace "OK" True = optBSParams' (-1E20) 

optBSParams' lastIter model t' params startBS mapping priors lower upper cutoff = optimal where
        tree = addModelFx (mySetBL t' (drop startBS params)) (model $ take startBS params) priors
        optParamsFunc = loggedFunc . boundedFunction (-1E20) lower upper . rawOptParamsFunc
        rawOptParamsFunc t p2  = logLikelihood $ addModelFx (mySetBL t (drop startBS p2)) (model (take startBS p2)) priors
        mySetBL t p = fst $ setBLflat 1 t (map (p!!) mapping)
        bestTree' | trace ("last iter " ++ (show tree)) True = optBLD0 $ addModelFx (mySetBL tree (drop startBS params)) (model (take startBS params)) priors
        (bestParams,_) | trace ("Opt tree " ++ (show bestTree') ++ "\n" ++ (show $ logLikelihood bestTree') ++ "\n" ++ (show $ logLikelihood (addModelFx (mySetBL bestTree' (drop startBS params)) (model $ take startBS params) priors )) ++ (show (addModelFx (mySetBL bestTree' (drop startBS params)) (model $ take startBS params) priors ) )) True =  maximize NMSimplex2 1E-4 100000 (map (\i->0.1) params) (optParamsFunc bestTree') params  
        bestTree = addModelFx (mySetBL bestTree' (drop startBS bestParams)) (model (take startBS bestParams)) priors
        thisIter | trace ("Best tree " ++ (show bestTree)) True = traceXP "iteration" $  logLikelihood bestTree
        optimal = doNext (thisIter - lastIter)
        doNext improvement | improvement < cutoff = (bestTree,bestParams)
        doNext improvement = optBSParams' thisIter model bestTree bestParams startBS mapping priors lower upper cutoff


        
optParamsAndBL model tree params priors lower upper cutoff = optParamsAndBL' model tree params priors lower upper cutoff (logLikelihood (addModelFx tree (model params) priors)) []  where                                                                                                                     

optParamsAndBL' :: (AddTree t) => ModelF -> t -> [Double] -> [Double] -> [Maybe Double] -> [Maybe Double] -> Double -> Double -> [Matrix Double] -> (DNode,[Double],[Matrix Double])  
optParamsAndBL' model tree params priors lower upper cutoff lastIter path | trace ("OK2" ++ (show lastIter)) $ True = optimal where                                                                                                                                                        
                                              tree' = optBL model tree params priors cutoff
                                              bestParams = optParams model tree' params priors lower upper cutoff
                                              bestTree = optBL model tree' bestParams priors cutoff
                                              thisIter = logLikelihood bestTree
                                              optimal = doNext (thisIter - lastIter)
                                              doNext improvement | improvement < cutoff = (bestTree,bestParams,path)
                                              doNext improvement | improvement < 0.1 = optParamsAndBL'' model bestTree bestParams priors lower upper cutoff thisIter path
                                              doNext improvement =  optParamsAndBL' model bestTree bestParams priors lower upper cutoff thisIter path                                                                                            

optParamsAndBL'' model tree params priors lower upper cutoff lastIter path = optParamsAndBL' model bestTree bestParams priors lower upper cutoff thisIter path where
                                                                        numParams = length params
                                                                        optFunc = loggedFunc $ boundedFunction (-1E20) (lower ++ (repeat $ Just 0.0)) (upper ++ (repeat Nothing)) rawFunc
                                                                        rawFunc testparams = logLikelihood $ addModelFx (fst $ setBLflat 0 tree (drop numParams testparams)) (model $ take numParams testparams) priors
                                                                        startParams = params ++ (getBL tree)
                                                                        (optParams,_) = maximize NMSimplex2 1E-4 100000 (map (\i->0.01) startParams) optFunc startParams
                                                                        (bestParams,bestBL) = splitAt numParams optParams
                                                                        bestTree = addModelFx (setBL bestBL tree) (model bestParams) priors
                                                                        thisIter = logLikelihood bestTree
--TODO eradicate this function!
dummyTree :: (AddTree t) => t -> DNode 
dummyTree t = addModelFx t (basicModel wagS wagPi []) [1.0]

makeMapping :: (AddTree t) => (([String],[String]) -> a) -> t -> [a]
makeMapping splitmap t = map splitmap (traceX (getSplits $ dummyTree t))

traceX x = traceShow x x
traceXP p x = trace (p ++ " " ++ (show x)) x
