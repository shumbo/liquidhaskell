{-# LANGUAGE MultiParamTypeClasses, NoMonomorphismRestriction, TypeSynonymInstances, FlexibleInstances, TupleSections, ScopedTypeVariables  #-}

-- | This module contains the functions that convert /from/ descriptions of 
-- symbols, names and types (over freshly parsed /bare/ Strings),
-- /to/ representations connected to GHC vars, names, and types.
-- The actual /representations/ of bare and real (refinement) types are all
-- in `RefType` -- they are different instances of `RType`

module Language.Haskell.Liquid.Bare (GhcSpec (..), makeGhcSpec) where

import GHC hiding (lookupName)	
import Outputable
import Var
import PrelNames
import PrelInfo     (wiredInThings)
import Type         (expandTypeSynonyms)
import DataCon      (dataConImplicitIds)
import HscMain
import TysWiredIn
import BasicTypes (TupleSort (..), Arity)
import TcRnDriver (tcRnLookupRdrName, tcRnLookupName) 

import Text.Printf
import Data.Maybe               (catMaybes)
import Data.Traversable         (forM)
import Control.Applicative      ((<$>))
import Control.Monad.Reader     hiding (forM)
import Control.Monad.Error      hiding (forM)
-- import Data.Data                hiding (TyCon, tyConName)
import Data.Bifunctor


import Language.Haskell.Liquid.GhcMisc hiding (L)
import Language.Haskell.Liquid.Fixpoint
import Language.Haskell.Liquid.RefType
import Language.Haskell.Liquid.PredType
import qualified Language.Haskell.Liquid.Measure as Ms
import Language.Haskell.Liquid.Misc

import qualified Data.List           as L
import qualified Data.HashSet        as S
import qualified Data.HashMap.Strict as M
import qualified Control.Exception as Ex

------------------------------------------------------------------
---------- Top Level Output --------------------------------------
------------------------------------------------------------------

-- | The following is the overall type for /specifications/ obtained from
-- parsing the target source and dependent libraries

data GhcSpec = SP {
    tySigs     :: ![(Var, SpecType)]     -- ^ Asserted/Assumed Reftypes
                                         -- eg.  see include/Prelude.spec
  , ctor       :: ![(Var, SpecType)]     -- ^ Data Constructor Measure Sigs 
                                         -- eg.  (:) :: a -> xs:[a] -> {v: Int | v = 1 + len(xs) }
  , meas       :: ![(Symbol, RefType)]   -- ^ Measure Types  
                                         -- eg.  len :: [a] -> Int
  , invariants :: ![SpecType]            -- ^ Data Type Invariants
                                         -- eg.  forall a. {v: [a] | len(v) >= 0}
  , dconsP     :: ![(DataCon, DataConP)] -- ^ Predicated Data-Constructors
                                         -- e.g. see tests/pos/Map.hs
  , tconsP     :: ![(TyCon, TyConP)]     -- ^ Predicated Type-Constructors
                                         -- eg.  see tests/pos/Map.hs
  , freeSyms   :: ![(Symbol, Var)]       -- ^ List of `Symbol` free in spec and corresponding GHC var 
                                         -- eg. (Cons, Cons#7uz) from tests/pos/ex1.hs
  , tcEmbeds   :: TCEmb TyCon            -- ^ How to embed GHC Tycons into fixpoint sorts
  }

makeGhcSpec :: [Var] -> HscEnv -> Ms.Spec BareType Symbol -> IO GhcSpec 
makeGhcSpec vars env spec 
  = do (tcs, dcs)      <- makeConTypes    env               $ Ms.dataDecls  spec 
       let (tcs', dcs') = wiredTyDataCons 
       let tycons       = tcs ++ tcs'    
       let datacons     = {- traceShow "ODD DCS" $ -} concat dcs ++ dcs'
       let benv         = BE (makeTyConInfo tycons) env
       (cs, ms)        <- makeMeasureSpec benv $ Ms.mkMSpec $ Ms.measures   spec
       sigs            <- makeAssumeSpec  benv vars         $ Ms.sigs       spec
       invs            <- makeInvariants  benv              $ Ms.invariants spec
       embs            <- makeTyConEmbeds benv              $ Ms.embeds     spec 
       let cs'          = {- traceShow "dataConSPEC" $ -} meetDataConSpec cs datacons
       let syms         = makeSymbols (vars ++ map fst cs') (map fst ms) (sigs ++ cs') ms 
       let tx           = subsFreeSymbols syms
       let syms'        = [(varSymbol v, v) | (_, v) <- syms]
       return           $ SP { tySigs     = tx sigs
                             , ctor       = tx cs'
                             , meas       = tx ms 
                             , invariants = invs 
                             , dconsP     = datacons
                             , tconsP     = tycons 
                             , freeSyms   = syms' 
                             , tcEmbeds   = embs 
                             }

subsFreeSymbols xvs = tx
  where su  = mkSubst [ (x, EVar (varSymbol v)) | (x, v) <- xvs]
        tx  = fmap $ mapSnd $ subst su {- (\t -> tracePpr ("subsFree: " ++ showPpr t) (subst su t)) -}

-- meetDataConSpec :: [(Var, SpecType)] -> [(DataCon, DataConP)] -> [(Var, SpecType)]
meetDataConSpec xts dcs  = M.toList $ L.foldl' upd dcm xts 
  where dcm              = dataConSpec dcs 
        upd dcm (x, t)   = M.insert x (maybe t (meetPad t) (M.lookup x dcm)) dcm
        strengthen (x,t) = (x, maybe t (meetPad t) (M.lookup x dcm))


-- dataConSpec :: [(DataCon, DataConP)] -> [(Var, SpecType)]
dataConSpec dcs = M.fromList [(v, dataConPSpecType t) | (dc, t) <- dcs, v <- dataConImplicitIds dc]

meetPad t1 t2 = -- traceShow ("meetPad: " ++ msg) $
  case (bkUniv t1, bkUniv t2) of
    ((_, π1s, _), (α2s, [], t2')) -> meet t1 (mkUnivs α2s π1s t2')
    ((α1s, [], t1'), (_, π2s, _)) -> meet (mkUnivs α1s π2s t1') t2
    _                             -> errorstar $ "meetPad: " ++ msg
  where msg = "\nt1 = " ++ showPpr t1 ++ "\nt2 = " ++ showPpr t2
 
------------------------------------------------------------------
---------- Error-Reader-IO For Bare Transformation ---------------
------------------------------------------------------------------

type BareM a = ErrorT String (ReaderT BareEnv IO) a

data BareEnv = BE { tcEnv  :: !(M.HashMap TyCon RTyCon)
                  , hscEnv :: HscEnv }

execBare :: BareM a -> BareEnv -> IO a
execBare act benv = 
   do z <- runReaderT (runErrorT act) benv
      case z of
        Left s  -> errorstar $ "execBare:" ++ s
        Right x -> return x

wrapErr msg f x
  = f x `catchError` \e-> throwError $ "Bare Error " ++ "[" ++ msg ++ "]" ++ showPpr x ++ "(" ++ e ++ ")"

------------------------------------------------------------------
------------------- API: Bare Refinement Types -------------------
------------------------------------------------------------------

makeMeasureSpec :: BareEnv -> Ms.MSpec BareType Symbol -> IO ([(Var, SpecType)], [(Symbol, RefType)])
makeMeasureSpec env m = execBare mkSpec env 
  where mkSpec = wrapErr "mkMeasureSort" mkMeasureSort m' 
                 >>= mkMeasureDCon 
                 >>= return . mapFst (mapSnd uRType <$>) . Ms.dataConTypes 
        m'     = first (mapReft ur_reft) m

makeAssumeSpec :: BareEnv -> [Var] -> [(Symbol, BareType)] -> IO [(Var, SpecType)]
makeAssumeSpec env vs xbs = execBare mkAspec env 
  where mkAspec = forM vbs mkVarSpec >>= return . checkAssumeSpec
        vbs     = joinIds vs xbs -- (first symbolString <$> xbs) 

mkVarSpec (v, b) = liftM (v,) (wrapErr msg (mkSpecType msg) b)
  where msg = "mkVarSpec fails on " ++ showPpr v ++ " :: "  ++ showPpr b 

joinIds vs xts = vts   
  where vm     = M.fromList [(showPpr v, v) | v <- vs]
        vts    = catMaybes [(, t) <$> (M.lookup (symbolString x) vm) | (x, t) <- xts]


makeTyConEmbeds  :: BareEnv -> TCEmb String -> IO (TCEmb TyCon) 
makeTyConEmbeds benv z = execBare (M.fromList <$> mapM tx (M.toList z)) benv
  where tx (c, y) = (, y) <$> lookupGhcTyCon c


makeInvariants :: BareEnv -> [BareType] -> IO [SpecType]
makeInvariants benv ts = execBare (mapM (mkSpecType "invariant") ts) benv

mkSpecType msg t = mkSpecType' msg πs t
  where πs   = (snd3 $ bkUniv t)

mkSpecType' :: String -> [PVar BSort] -> BareType -> BareM SpecType
mkSpecType' msg πs 
  = ofBareType' msg πs
  . txParams subvUReft (uPVar <$> πs)
  . mapReft (fmap canonReft) 

makeSymbols vs xs' xts yts = 
  -- tracePpr ("makeSymbols: vs = " ++ showPpr vs ++ " xs' = " ++ showPpr xs' ++ " ts = " ++ showPpr xts) $ 
  if (all (checkSig env) xts) && (all (checkSig env) yts) 
   then xvs 
   else errorstar "malformed type signatures" 
  where zs  = (concatMap freeSymbols ((snd <$> xts))) `sortDiff` xs'
        zs' = (concatMap freeSymbols ((snd <$> yts))) `sortDiff` xs'
        xs  = sortNub $ zs ++ zs'
        xvs = sortNub [(x,v) | (v, x) <- joinIds vs (zip xs xs)]
        env = S.fromList ((fst <$> xvs) ++ xs')

-- TODO: use this. currently suppressed because 
checkSig env xt = True 

--   forall aa. (Ord a) => [a] -> [a]<{VV : a | (VV >= fld)}>
-- doesn't typecheck -- thanks to "fld"
-- checkSig env xt = tracePpr ("checkSig " ++ showPpr xt) $ checkSig' env xt

checkSig' env (x, t) 
  = case filter (not . (`S.member` env)) (freeSymbols t) of
      [] -> True
      ys -> errorstar (msg ys) 
    where msg ys = printf "Unkown free symbols: %s in specification for %s \n%s\n" (showPpr ys) (showPpr x) (showPpr t)

-- freeSymbols :: SpecType -> [Symbol]
freeSymbols ty   = -- tracePpr ("freeSymbols: " ++ show ty) $ 
                   sortNub $ concat $ efoldReft f [] [] ty
  where f γ r xs = let Reft (v, ras) = toReft r in ((syms ras) `sortDiff` (v:γ) ) : xs 

-----------------------------------------------------------------
------ Querying GHC for Id, Type, Class, Con etc. ---------------
-----------------------------------------------------------------

class GhcLookup a where
  lookupName :: HscEnv -> a -> IO (Maybe Name)
  candidates :: a -> [a]
  pp         :: a -> String 

instance GhcLookup String where
  lookupName     = stringLookup
  candidates x   = [x, swizzle x] 
  pp         x   = x

swizzle =  dropModuleNames . stripParens

instance GhcLookup Name where
  lookupName _   = return . Just
  candidates x   = [x]
  pp             = showPpr  

-- existsGhcThing :: (GhcLookup a) => String -> (TyThing -> Maybe b) -> a -> BareM Bool 
-- existsGhcThing name f x 
--   = do z <- lookupGhcThing' name f x
--        case z of 
--          Just _ -> return True
--          _      -> return False

lookupGhcThing :: (GhcLookup a) => String -> (TyThing -> Maybe b) -> a -> BareM b
lookupGhcThing name f x 
  = do zs <- catMaybes <$> mapM (lookupGhcThing' name f) (candidates x)
       case zs of 
         x:_ -> return x
         _   -> throwError $ "lookupGhcThing unknown " ++ name ++ " : " ++ (pp x)

lookupGhcThing' :: (GhcLookup a) => String -> (TyThing -> Maybe b) -> a -> BareM (Maybe b)
lookupGhcThing' _    f x 
  = do env     <- hscEnv <$> ask
       z       <- liftIO $ lookupName env x
       case z of
         Nothing -> return Nothing 
         Just n  -> liftIO $ liftM (join . (f <$>) . snd) (tcRnLookupName env n)

stringLookup :: HscEnv -> String -> IO (Maybe Name)
stringLookup env k
  | k `M.member` wiredIn
  = return $ M.lookup k wiredIn
  | last k == '#'
  = return Nothing -- errorstar $ "Unknown Primitive Thing: " ++ k
  | otherwise
  = stringLookupEnv env k

stringLookupEnv env s 
    = do L _ rn         <- hscParseIdentifier env s
         (_, lookupres) <- tcRnLookupRdrName env rn
         case lookupres of
           Just (n:_) -> return (Just n)
           _          -> return Nothing

lookupGhcTyCon = lookupGhcThing "TyCon" ftc 
  where ftc (ATyCon x) = Just x
        ftc _          = Nothing

lookupGhcClass = lookupGhcThing "Class" ftc 
  where ftc (ATyCon x) = tyConClass_maybe x 
        ftc _          = Nothing

lookupGhcDataCon = lookupGhcThing "DataCon" fdc 
  where fdc (ADataCon x) = Just x
        fdc _            = Nothing

-- lookupGhcId = lookupGhcThing "Id" thingId

-- existsGhcId = existsGhcThing "Id" thingId
-- existsGhcId s = 
--   do z <- or <$> mapM (existsGhcThing "Id" thingId) (candidates s)
--      if z 
--        then return True 
--        else return (warnShow ("existsGhcId " ++ s) $ False)


-- thingId (AnId x)     = Just x
-- thingId (ADataCon x) = Just $ dataConWorkId x
-- thingId _            = Nothing

wiredIn :: M.HashMap String Name
wiredIn = M.fromList $ {- tracePpr "wiredIn: " $ -} special ++ wiredIns 
  where wiredIns = [ (showPpr n, n) | thing <- wiredInThings, let n = getName thing ]
        special  = [ ("GHC.Integer.smallInteger", smallIntegerName)
                   , ("GHC.Num.fromInteger"     , fromIntegerName ) ]

--------------------------------------------------------------------
------ Predicate Types for WiredIns --------------------------------
--------------------------------------------------------------------

maxArity :: Arity 
maxArity = 7

wiredTyDataCons :: ([(TyCon, TyConP)] , [(DataCon, DataConP)])
wiredTyDataCons = (\(x, y) -> (concat x, concat y)) $ unzip l
  where l = [listTyDataCons] ++ map tupleTyDataCons [1..maxArity] 

listTyDataCons :: ([(TyCon, TyConP)] , [(DataCon, DataConP)])
listTyDataCons   = ( [(c, TyConP [(RTV tyv)] [p])]
                   , [(nilDataCon , DataConP [(RTV tyv)] [p] [] lt)
                   , (consDataCon, DataConP [(RTV tyv)] [p]  cargs  lt)])
    where c      = listTyCon
          [tyv]  = tyConTyVars c
          t      = {- TyVarTy -} rVar tyv :: RSort
          fld    = stringSymbol "fld"
          x      = stringSymbol "x"
          xs     = stringSymbol "xs"
          p      = PV (stringSymbol "p") t [(t, fld, fld)]
          px     = (pdVarReft $ PV (stringSymbol "p") t [(t, fld, x)]) 
          lt     = rApp c [xt] [RMono $ pdVarReft p] top                 
          xt     = rVar tyv
          xst    = rApp c [RVar (RTV tyv) px] [RMono $ pdVarReft p] top  
          cargs  = [(xs, xst), (x, xt)]
 

tupleTyDataCons :: Int -> ([(TyCon, TyConP)] , [(DataCon, DataConP)])
tupleTyDataCons n = ( [(c, TyConP (RTV <$> tyvs) ps)]
                    , [(dc, DataConP (RTV <$> tyvs) ps  cargs  lt)])
  where c             = tupleTyCon BoxedTuple n
        dc            = tupleCon BoxedTuple n 
        tyvs@(tv:tvs) = tyConTyVars c
        (ta:ts)       = (rVar <$> tyvs) :: [RSort]
        flds          = mks "fld"
        fld           = stringSymbol "fld"
        x1:xs         = mks "x"
        -- y             = stringSymbol "y"
        ps            = mkps pnames (ta:ts) ((fld,fld):(zip flds flds))
        ups           = uPVar <$> ps
        pxs           = mkps pnames (ta:ts) ((fld, x1):(zip flds xs))
        lt            = rApp c (rVar <$> tyvs) (RMono . pdVarReft <$> ups) top
        xts           = zipWith (\v p -> RVar (RTV v) (pdVarReft p)) tvs pxs
        cargs         = reverse $ (x1, rVar tv) : (zip xs xts)
        pnames        = mks_ "p"
        mks  x        = (\i -> stringSymbol (x++ show i)) <$> [1..n]
        mks_ x        = (\i ->  (x++ show i)) <$> [2..n]


pdVarReft = U top . pdVar 

mkps ns (t:ts) ((f,x):fxs) = reverse $ mkps_ (stringSymbol <$> ns) ts fxs [(t, f, x)] [] 
mkps _  _      _           = error "Bare : mkps"

mkps_ []     _       _          _    ps = ps
mkps_ (n:ns) (t:ts) ((f, x):xs) args ps
  = mkps_ ns ts xs (a:args) (p:ps)
  where p = PV n t args
        a = (t, f, x)
mkps_ _     _       _          _    _ = error "Bare : mkps_"

------------------------------------------------------------------------
----------------- Transforming Raw Strings using GHC Env ---------------
------------------------------------------------------------------------


ofBareType' msg πs = wrapErr "ofBareType" ofBareType 

ofBareType :: Reftable r => RType String String String r -> BareM (RType Class RTyCon RTyVar r)
ofBareType (RVar a r) 
  = return $ RVar (stringRTyVar a) r
ofBareType (RFun x t1 t2 _) 
  = liftM2 (rFun x) (ofBareType t1) (ofBareType t2)
ofBareType (REx x t1 t2)
  = liftM2 (REx x) (ofBareType t1) (ofBareType t2)
ofBareType (RAllT a t) 
  = liftM  (RAllT (stringRTyVar a)) (ofBareType t)
ofBareType (RAllP π t) 
  = liftM2 RAllP (ofBPVar π) (ofBareType t)
ofBareType (RApp tc ts@[_] rs r) 
  | isList tc
  = do tyi <- tcEnv <$> ask
       liftM2 (bareTCApp tyi r listTyCon) (mapM ofRef rs) (mapM ofBareType ts)
ofBareType (RApp tc ts rs r) 
  | isTuple tc
  = do tyi <- tcEnv <$> ask
       liftM2 (bareTCApp tyi r c) (mapM ofRef rs) (mapM ofBareType ts)
    where c = tupleTyCon BoxedTuple (length ts)
ofBareType (RApp tc ts rs r) 
  = do tyi <- tcEnv <$> ask
       liftM3 (bareTCApp tyi r) (lookupGhcTyCon tc) (mapM ofRef rs) (mapM ofBareType ts)
ofBareType (RCls c ts)
  = liftM2 RCls (lookupGhcClass c) (mapM ofBareType ts)
ofBareType _
  = error "Bare : ofBareType"

ofRef (RPoly t)   
  = liftM RPoly (ofBareType t)
ofRef (RMono r) 
  = return (RMono r)

-- TODO: move back to RefType
bareTCApp _ r c rs ts 
  = if isTrivial t0 then t' else t
    where t0 = rApp c ts rs top
          t  = rApp c ts rs r
          t' = (expandRTypeSynonyms t0) `strengthen` r

expandRTypeSynonyms = ofType . expandTypeSynonyms . toType

stringRTyVar  = rTyVar . stringTyVar 
-- stringTyVarTy = TyVarTy . stringTyVar



mkMeasureDCon :: Ms.MSpec t Symbol -> BareM (Ms.MSpec t DataCon)
mkMeasureDCon m = (forM (measureCtors m) $ \n -> liftM (n,) (lookupGhcDataCon n))
                  >>= (return . mkMeasureDCon_ m)

mkMeasureDCon_ :: Ms.MSpec t Symbol -> [(String, DataCon)] -> Ms.MSpec t DataCon
mkMeasureDCon_ m ndcs = m' {Ms.ctorMap = cm'}
  where m'  = fmap tx m
        cm' = hashMapMapKeys (dataConSymbol . tx) $ Ms.ctorMap m'
        tx  = mlookup (M.fromList ndcs) . symbolString

measureCtors ::  Ms.MSpec t Symbol -> [String]
measureCtors = sortNub . fmap (symbolString . Ms.ctor) . concat . M.elems . Ms.ctorMap 

-- mkMeasureSort :: (PVarable pv, Reftable r) => Ms.MSpec (BRType pv r) bndr-> BareM (Ms.MSpec (RRType pv r) bndr)
mkMeasureSort (Ms.MSpec cm mm) 
  = liftM (Ms.MSpec cm) $ forM mm $ \m -> 
      liftM (\s' -> m {Ms.sort = s'}) (ofBareType' "mkMeasureSort" [] (Ms.sort m))

-----------------------------------------------------------------------
---------------- Bare Predicate: DataCon Definitions ------------------
-----------------------------------------------------------------------

makeConTypes :: HscEnv -> [DataDecl] -> IO ([(TyCon, TyConP)], [[(DataCon, DataConP)]])
makeConTypes env dcs = unzip <$> execBare (mapM ofBDataDecl dcs) (BE M.empty env)

ofBDataDecl :: DataDecl -> BareM ((TyCon, TyConP), [(DataCon, DataConP)])
ofBDataDecl (D tc as ps cts)
  = do πs    <- mapM ofBPVar ps
       tc'   <- lookupGhcTyCon tc 
       cts'  <- mapM (ofBDataCon tc' αs ps πs) cts     -- cpts
       return $ ((tc', TyConP αs πs), cts')
    where αs   = fmap (RTV . stringTyVar) as
          -- cpts = fmap (second (fmap (second (mapReft ur_pred)))) cts

-- ofBPreds = fmap (fmap stringTyVarTy)
ofBPVar :: PVar BSort -> BareM (PVar RSort)
ofBPVar = mapM_pvar ofBareType 

mapM_pvar :: (Monad m) => (a -> m b) -> PVar a -> m (PVar b)
mapM_pvar f (PV x t txys) 
  = do t'    <- f t
       txys' <- mapM (\(t, x, y) -> liftM (, x, y) (f t)) txys 
       return $ PV x t' txys'

ofBDataCon tc αs ps πs (c, xts)
 = do c'    <- lookupGhcDataCon c
      ts'   <- mapM (mkSpecType' msg ps) ts
      let t0 = rApp tc rs (RMono . pdVarReft <$> πs) top 
      return $ (c', DataConP αs πs (reverse (zip xs' ts')) t0) 
 where (xs, ts) = unzip xts
       xs'      = map stringSymbol xs
       rs       = [rVar α | RTV α <- αs] -- [RVar α pdTrue | α <- αs]
       msg      = "ofBDataCon " ++ showPpr c ++ " with πs = " ++ showPpr πs

-----------------------------------------------------------------------
---------------- Bare Predicate: RefTypes -----------------------------
-----------------------------------------------------------------------

txParams f πs t = mapReft (f (txPvar (predMap πs t))) t

txPvar :: M.HashMap Symbol UsedPVar -> UsedPVar -> UsedPVar 
txPvar m π = π { pargs = args' }
  where args' = zipWith (\(_,x ,_) (t,_,y) -> (t, x, y)) (pargs π') (pargs π)
        π'    = M.lookupDefault (errorstar err) (pname π) m
        err   = "Bare.replaceParams Unbound Predicate Variable: " ++ show π

predMap πs t = Ex.assert (M.size xπm == length xπs) xπm 
  where xπm = M.fromList xπs
        xπs = [(pname π, π) | π <- πs ++ rtypePredBinds t]

rtypePredBinds = map uPVar . snd3 . bkUniv

-- rtypePredBinds t = everything (++) ([] `mkQ` grab) t
--   where grab ((RAllP pv _) :: BRType RPVar RPredicate) = [pv]
--         grab _                                         = []

-------------------------------------------------------------------------------
------- Checking Specifications Refine Haskell Types --------------------------
-------------------------------------------------------------------------------

checkAssumeSpec xts 
  = case filter specMismatch xts of 
      []  -> xts
      yts -> errorstar $ specificationError yts

specificationError yts = unlines $ "Error in Reftype Specification" : concatMap err yts 
  where err (y, t) = [ "Haskell: " ++ showPpr y ++ " :: " ++ showPpr (varType y)
                     , "Liquid : " ++ showPpr y ++ " :: " ++ showPpr t           ]
  
specMismatch (x, t) 
  =  not $ (toRSort t) == (ofType $ varType x) 

---------------------------------------------------------------------------------
----------------- Helper Predicates on Types ------------------------------------
---------------------------------------------------------------------------------

-- eqType' τ1 τ2 = eqType τ1 τ2 

-- eqShape :: SpecType -> SpecType -> Bool 
-- eqShape t1 t2 = eqShape (toRSort t1) (toRSort t2) 



