
{-
  Author: George Karachalias <george.karachalias@cs.kuleuven.be>
-}

{-# OPTIONS_GHC -Wwarn #-}   -- unused variables

{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds, GADTs, KindSignatures #-}

module Check ( checkpm, PmResult, pprUncovered, toTcTypeBag ) where

#include "HsVersions.h"

import HsSyn
import TcHsSyn
import DsUtils
import MatchLit
import Id
import ConLike
import DataCon
import Name
import TysWiredIn
import TyCon
import SrcLoc
import Util
import BasicTypes
import Outputable
import FastString
import Unify( tcMatchTys )

-- For the new checker (We need to remove and reorder things)
import DsMonad ( DsM, initTcDsForSolver, getDictsDs, getSrcSpanDs)
import TcSimplify( tcCheckSatisfiability )
import UniqSupply (MonadUnique(..))
import TcType ( mkTcEqPred, toTcType, toTcTypeBag )
import VarSet
import Bag
import ErrUtils
import TcMType (genInstSkolTyVarsX)
import IOEnv (tryM, failM)

import Data.Maybe (isJust)
import Control.Monad ( forM, zipWithM )

import MonadUtils -- MonadIO
import Var (EvVar)
import Type

import TcRnTypes  ( pprInTcRnIf ) -- Shouldn't be here
import TysPrim    ( anyTy )       -- Shouldn't be here
import UniqSupply ( UniqSupply
                  , splitUniqSupply      -- :: UniqSupply -> (UniqSupply, UniqSupply)
                  , listSplitUniqSupply  -- :: UniqSupply -> [UniqSupply]
                  , uniqFromSupply )     -- :: UniqSupply -> Unique

import Control.Monad.Trans.Except -- For the term solver

{-
This module checks pattern matches for:
\begin{enumerate}
  \item Equations that are totally redundant (can be removed from the match)
  \item Exhaustiveness, and returns the equations that are not covered by the match
  \item Equations that are completely overlapped by other equations yet force the
        evaluation of some arguments (but have inaccessible right hand side).
\end{enumerate}

The algorithm used is described in the following paper:
  NO PAPER YET!

%************************************************************************
%*                                                                      *
\subsection{Pattern Match Check Types}
%*                                                                      *
%************************************************************************
-}

-- | Literal patterns for the pattern match check. Almost identical to LitPat
-- and NPat data constructors of type (Pat id) in file hsSyn/HsPat.lhs
data PmLit id = PmLit HsLit
              | PmOLit (HsOverLit id) Bool -- True <=> negated

instance Eq (PmLit id) where
  PmLit  l1       == PmLit  l2       = l1 == l2
  PmOLit l1 True  == PmOLit l2 True  = l1 == l2
  PmOLit l1 False == PmOLit l2 False = l1 == l2
  _               == _               = False

-- | The main pattern type for pattern match check. Only guards, variables,
-- constructors, literals and negative literals. It it sufficient to represent
-- all different patterns, apart maybe from bang and lazy patterns.

-- SPJ... Say that this the term-level stuff only.
-- Drop all types, existential type variables
--
data PmPat id = PmGuardPat PmGuard -- Note [Translation to PmPat]
              | PmVarPat id
              | PmConPat DataCon [PmPat id]
              | PmLitPat (PmLit id)
              | PmLitCon [PmLit id] -- Note [Negative patterns]

-- | Guard representation for the pattern match check. Just represented as a
-- CanItFail for now but can be extended to carry more useful information
type PmGuard = CanItFail

-- | A pattern vector may either force or not the evaluation of an argument.
-- Instead of keeping track of which arguments and under which conditions (like
-- we do in the paper), we simply keep track of if it forces anything or not
-- (That is the only thing that we care about anyway)
type Forces = Bool
type Covers = Bool

type SimpleVec = [PmPat Id]        -- NB: No PmGuardPat patterns
type InVec  = [PmPat Id]           -- NB: No PmLitCon patterns
type OutVec = (PmGuard, SimpleVec) -- NB: No PmGuardPat patterns

type Uncovered = Bag OutVec        -- NB: No PmGuardPat patterns
type Covered   = Bag OutVec        -- NB: No PmGuardPat patterns

-- | The result of pattern match check. A tuple containing:
--   * Clauses that are redundant (do not cover anything, do not force anything)
--   * Clauses with inaccessible rhs (do not cover anything, yet force something)
--   * Uncovered cases (in PmPat form)
type PmResult = ([EquationInfo], [EquationInfo], [OutVec])

type PmM a = DsM a -- just a renaming to remove later (maybe keep this)


{-
%************************************************************************
%*                                                                      *
\subsection{Entry point to the checker: checkpm}
%*                                                                      *
%************************************************************************
-}

-- ----------------------------------------------------------------------------
-- Check what we generate

check_covered_uncovered :: [Type] -> [EquationInfo] -> DsM ()
check_covered_uncovered tys eq_infos = do
  loc <- getSrcSpanDs
  pprInTcRnIf (ptext (sLit "Checking match at:") <+> ppr loc)
  usupply <- getUniqueSupplyM
  let missing = initial_uncovered2 usupply tys
  check_covered_uncovered' eq_infos missing

check_covered_uncovered' :: [EquationInfo] -> ValSetAbs -> DsM () -- Get Initial Uncovered As Argument
check_covered_uncovered' eq_infos missing
  | null eq_infos = return () -- Do not print final uncovered, we do it in every step
  | otherwise = do
      pprInTcRnIf (ptext (sLit "Processing clause:") <+> ppr (head eq_infos))

      -- Translate current clause
      usupply  <- getUniqueSupplyM
      let translated = translateEqnInfo usupply (head eq_infos)
      pprInTcRnIf (ptext (sLit "Translation:") <+> ppr translated)

      -- Compute and print covered and uncovered
      usupplyc <- getUniqueSupplyM -- for covered
      let cv  = covered usupplyc translated missing
      pprInTcRnIf $ hang (ptext (sLit "Covers:")) 2 (ppr cv)

      usupplyu <- getUniqueSupplyM -- for uncovered
      let uv  = uncovered usupplyu translated missing
      pprInTcRnIf $ hang (ptext (sLit "Left uncovered:")) 2 (ppr uv)

      check_covered_uncovered' (tail eq_infos) uv
-- ----------------------------------------------------------------------------

checkpm :: [Type] -> [EquationInfo] -> DsM (Maybe PmResult)
checkpm tys eq_info
  | null eq_info = return (Just ([],[],[])) -- If we have an empty match, do not reason at all
  | otherwise = do

      -- ---------------------------------------------------------------------
      -- Checking our stuff
      check_covered_uncovered tys eq_info
      -- ---------------------------------------------------------------------

      uncovered0 <- initial_uncovered tys
      res <- tryM (checkpm' tys uncovered0 eq_info)
      case res of
        Left _    -> return Nothing
        Right ans -> return (Just ans)

-- Worker (recursive)
checkpm' :: [Type] -> Uncovered -> [EquationInfo] -> PmM PmResult
checkpm' _tys uncovered_set [] = return ([],[], bagToList uncovered_set)
checkpm'  tys uncovered_set (eq_info:eq_infos) = do
  invec <- preprocess_match eq_info
  (covers, us, forces) <- process_vector tys uncovered_set invec
  let (redundant, inaccessible)
        | covers    = ([],        [])        -- At least one of cs is satisfiable
        | forces    = ([],        [eq_info]) -- inaccessible rhs
        | otherwise = ([eq_info], [])        -- redundant
  (redundants, inaccessibles, missing) <- checkpm' tys us eq_infos
  return (redundant ++ redundants, inaccessible ++ inaccessibles, missing)

-- -----------------------------------------------------------------------
-- | Initial uncovered. This is a set of variables that use the
-- appropriate super kind, the one we get from the signature.
-- Apart from that, the fresh variables have all type variables
-- as type and not something more specific.

initial_uncovered :: [Type] -> PmM Uncovered
initial_uncovered sig = do
  vec <- mapM (freshPmVar . toTcType . expandTypeSynonyms) sig
  return $ unitBag (guardDoesntFail, vec)

initial_uncovered2 :: UniqSupply -> [Type] -> ValSetAbs
initial_uncovered2 usupply tys = foldr Cons Singleton val_abs_vec
  where
    uniqs_tys   = listSplitUniqSupply usupply `zip` tys
    val_abs_vec = map (uncurry mkPmVar) uniqs_tys

{-
%************************************************************************
%*                                                                      *
\subsection{Transform EquationInfos to InVecs}
%*                                                                      *
%************************************************************************

Note [Translation to PmPat]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
The main translation of @Pat Id@ to @PmPat Id@ is performed by @mViewPat@.

Note that it doesn't return a @PmPat Id@ but @[PmPat Id]@ instead. This happens
because some patterns may introduce a guard in the middle of the vector. For example:

\begin{itemize}
  \item View patterns. Pattern @g -> pat@ must be translated to @[x, pat <- g x]@
        where x is a fresh variable
  \item n+k patterns. Pattern @n+k@ must be translated to @[n', n'>=k, let n = n'-k]@
        where @n'@ is a fresh variable
  \item We do something similar with overloaded lists and pattern synonyms since we
        do not know how to handle them yet. They are both translated into a fresh
        variable and a guard that can fail, but doesn't carry any more information
        with it
\end{itemize}

Note [Negative patterns]
~~~~~~~~~~~~~~~~~~~~~~~~
For the repsesentation of literal patterns we use constructors @PmLitPat@ and
@PmLitCon@ (constrained literal pattern). Note that from translating @Pat Id@
we never get a @PmLitCon@. It can appear only in @CoveredVec@ and @UncoveredVec@.
We generate @PmLitCon@s in cases like the following:
\begin{verbatim}
f :: Int -> Int
f 5 = 1
\end{verbatim}

Where we generate an uncovered vector of the form @PmLitCon Int x [5]@ which can
be read as ``all literals @x@ of type @Int@, apart from @5@''.
-}

-- -----------------------------------------------------------------------
-- | Entry point for the translation of source patterns (EquationInfo) to
-- input patterns (InVec).
preprocess_match :: EquationInfo -> PmM [PmPat Id]
preprocess_match (EqnInfo { eqn_pats = ps, eqn_rhs = mr }) =
  mapM mViewPat ps >>= return . foldr (++) [preprocessMR mr]
  where
    preprocessMR :: MatchResult -> PmPat Id
    preprocessMR (MatchResult can_fail _) = PmGuardPat can_fail

-- -----------------------------------------------------------------------
-- | Transform a Pat Id into a list of (PmPat Id) -- Note [Translation to PmPat]
mViewPat :: Pat Id -> PmM [PmPat Id]
mViewPat pat@(WildPat _) = pure <$> varFromPat pat
mViewPat (VarPat id)     = return [PmVarPat id]
mViewPat (ParPat p)      = mViewPat (unLoc p)
mViewPat pat@(LazyPat _) = pure <$> varFromPat pat
mViewPat (BangPat p)     = mViewPat (unLoc p)
mViewPat (AsPat _ p)     = mViewPat (unLoc p)
mViewPat (SigPatOut p _) = mViewPat (unLoc p)
mViewPat (CoPat   _ p _) = mViewPat p

-- -----------------------------------------------------------------------
-- | Cases where the algorithm is too conservative. See Note [Translation to PmPat]
mViewPat pat@(NPlusKPat _ _ _ _)                         = unhandled_case pat
mViewPat pat@(ViewPat _ _ _)                             = unhandled_case pat
mViewPat pat@(ListPat _ _ (Just (_,_)))                  = unhandled_case pat
mViewPat pat@(ConPatOut { pat_con = L _ (PatSynCon _) }) = unhandled_case pat

mViewPat (ConPatOut { pat_con = L _ (RealDataCon con), pat_args = ps }) = do
  args <- mViewConArgs con ps
  return [PmConPat con args]

mViewPat (NPat lit mb_neg eq) =
  case pmTidyNPat lit mb_neg eq of -- Note [Tidying literals for pattern matching] in MatchLit.lhs
    LitPat lit -> do -- Explain why this is important
      return [PmLitPat (PmLit lit)] -- transformed into simple literal
    NPat lit mb_neg _eq ->
      return [PmLitPat (PmOLit lit (isJust mb_neg))] -- remained as is (not enough information)
    pat -> mViewPat pat -- it was translated to sth else (constructor) -- only with a string this happens

mViewPat (LitPat lit) =
  case pmTidyLitPat lit of -- Note [Tidying literals for pattern matching] in MatchLit.lhs
    LitPat lit -> do
      return [PmLitPat (PmLit lit)]
    pat -> mViewPat pat -- it was translated to sth else (constructor)

mViewPat (ListPat ps _ Nothing) = do
  tidy_ps <- mapM (mViewPat . unLoc) ps
  let mkListPat x y = [PmConPat consDataCon (x++y)]
  return $ foldr mkListPat [PmConPat nilDataCon []] tidy_ps

-- fake parallel array constructors so that we can handle them
-- like we do with normal constructors
mViewPat (PArrPat ps _) = do
  tidy_ps <- mapM (mViewPat . unLoc) ps
  let fake_con = parrFakeCon (length ps)
  return [PmConPat fake_con (concat tidy_ps)]

mViewPat (TuplePat ps boxity _) = do
  tidy_ps <- mapM (mViewPat . unLoc) ps
  let tuple_con = tupleCon (boxityNormalTupleSort boxity) (length ps)
  return [PmConPat tuple_con (concat tidy_ps)]

mViewPat (ConPatIn {})      = panic "Check.mViewPat: ConPatIn"
mViewPat (SplicePat {})     = panic "Check.mViewPat: SplicePat"
mViewPat (QuasiQuotePat {}) = panic "Check.mViewPat: QuasiQuotePat"
mViewPat (SigPatIn {})      = panic "Check.mViewPat: SigPatIn"

-- -----------------------------------------------------------------------
-- | Trnasform construtor arguments to PmPats. The only reason this is a
-- separate function is that in case of Records, we have to fill the missing
-- arguments with wildcards.
mViewConArgs :: DataCon -> HsConPatDetails Id -> PmM [PmPat Id]
mViewConArgs _ (PrefixCon ps)   = concat <$> mapM (mViewPat . unLoc) ps
mViewConArgs _ (InfixCon p1 p2) = concat <$> mapM (mViewPat . unLoc) [p1,p2]
mViewConArgs c (RecCon (HsRecFields fs _))
  | null fs   = mapM freshPmVar (dataConOrigArgTys c)
  | otherwise = do
      let field_pats = map (\lbl -> (lbl, noLoc (WildPat (dataConFieldType c lbl)))) (dataConFieldLabels c)
          all_pats   = foldr (\(L _ (HsRecField id p _)) acc -> insertNm (getName (unLoc id)) p acc)
                             field_pats fs
      concat <$> mapM (mViewPat . unLoc . snd) all_pats
  where
    insertNm nm p [] = [(nm,p)]
    insertNm nm p (x@(n,_):xs)
      | nm == n    = (nm,p):xs
      | otherwise  = x : insertNm nm p xs

{-
%************************************************************************
%*                                                                      *
\subsection{Main Pattern Matching Check}
%*                                                                      *
%************************************************************************
-}

-- -----------------------------------------------------------------------
-- | Not like the paper. This version performs the syntactic part but checks for
-- well-typedness as well. It is like judgement `pm' but returns booleans for
-- redundancy and elimination (not empty/non-empty sets as `pm' does).
process_vector :: [Type] -> Uncovered -> InVec -> PmM (Covers, Uncovered, Forces)
process_vector sig uncovered clause = do
  covered <- alg_covers_many uncovered clause
  covers  <- anyBagM checkwt covered
  forces  <- alg_forces_many uncovered clause
  uncovered    <- alg_uncovered_many uncovered clause
  uncovered_wt <- filterBagM checkwt uncovered
  return (covers, uncovered_wt, forces)
  where
    checkwt = wt sig

-- -----------------------------------------------------------------------
-- | Set versions of `alg_covers', `alg_forces' and `alg_uncovered'
alg_covers_many :: Uncovered -> InVec -> PmM Covered
alg_covers_many uncovered clause = do
  covered <- mapBagM (\uvec -> alg_covers uvec clause) uncovered
  return (concatBag covered)

alg_forces_many :: Uncovered -> InVec -> PmM Bool
alg_forces_many uncovered clause
  = anyBagM (\uvec -> alg_forces uvec clause) uncovered

alg_uncovered_many :: Uncovered -> InVec -> PmM Uncovered
alg_uncovered_many uncovered clause = do
  uncovered' <- mapBagM (\uvec -> alg_uncovered uvec clause) uncovered
  return (concatBag uncovered')

-- -----------------------------------------------------------------------
-- | Given an uncovered value vector and a clause, check whether the clause
-- forces the evaluation of any arguments.
alg_forces :: OutVec -> InVec -> PmM Forces

-- empty
alg_forces (_,[]) [] = return False

-- any-var
alg_forces (guards, _ : us) ((PmVarPat _) : ps)
  = alg_forces (guards, us) ps

-- con-con
alg_forces (guards, (PmConPat con1 ps1) : us) ((PmConPat con2 ps2) : ps)
  | con1 == con2 = alg_forces (guards, ps1 ++ us) (ps2 ++ ps)
  | otherwise    = return False

-- var-con
alg_forces (_, (PmVarPat _):_) ((PmConPat _ _) : _) = return True

-- any-guard
alg_forces (guards, us) ((PmGuardPat g) : ps)
  | forcesGuard g = return True
  | otherwise     = alg_forces (guards, us) ps

-- lit-lit
alg_forces (guards, ((PmLitPat lit) : us)) ((PmLitPat lit') : ps)
  | lit /= lit' = return False
  | otherwise   = alg_forces (guards, us) ps

-- nlit-lit
alg_forces (guards, (PmLitCon ls) : us) ((PmLitPat lit) : ps)
  | lit `elem` ls = return False
  | otherwise     = alg_forces (guards, us) ps

-- var-lit
alg_forces (_, (PmVarPat _) : _) ((PmLitPat _) : _) = return True

-- give-up
alg_forces _ _ = give_up

-- -----------------------------------------------------------------------
-- | Given an uncovered value vector and a clause, compute the subset of vectors
-- that remain uncovered.
alg_uncovered :: OutVec -> InVec -> PmM Uncovered

-- empty
alg_uncovered (_,[]) [] = return emptyBag

-- any-var
alg_uncovered (guards, u : us) ((PmVarPat _var) : ps) =
  mapOutVecBag (u:) <$> alg_uncovered (guards, us) ps

-- con-con
alg_uncovered (guards, uvec@((PmConPat con1 ps1) : us)) ((PmConPat con2 ps2) : ps)
  | con1 == con2 = mapOutVecBag (zip_con con1) <$> alg_uncovered (guards, ps1 ++ us) (ps2 ++ ps)
  | otherwise    = return $ unitBag (guards, uvec)

-- var-con
alg_uncovered (guards, (PmVarPat _var):us) vec@((PmConPat con _) : _) = do
  all_con_pats <- mapM mkConFull (allConstructors con)
  uncovered <- forM all_con_pats $ \con_pat ->
    alg_uncovered (guards, con_pat:us) vec
  return $ unionManyBags uncovered

-- any-guard
alg_uncovered (guards, us) ((PmGuardPat g) : ps) = do
  rec_uncovered <- alg_uncovered (guards, us) ps
  return $ if guards `impliesGuard` g
             then rec_uncovered
             else (guards,us) `consBag` rec_uncovered

-- lit-lit
alg_uncovered (guards, uvec@((p@(PmLitPat lit)) : us)) ((PmLitPat lit') : ps)
  | lit /= lit' = return $ unitBag (guards, uvec)
  | otherwise   = mapOutVecBag (p:) <$> alg_uncovered (guards, us) ps

-- nlit-lit
alg_uncovered (guards, uvec@((PmLitCon ls) : us)) (p@(PmLitPat lit) : ps)
  | lit `elem` ls = return $ unitBag (guards, uvec)
  | otherwise = do
      rec_uncovered <- mapOutVecBag (p:) <$> alg_uncovered (guards, us) ps
      let u_uncovered = (guards, (PmLitCon (lit:ls)) : us)
      return $ u_uncovered `consBag` rec_uncovered

-- var-lit
alg_uncovered (guards, (PmVarPat _var) : us) ((p@(PmLitPat lit)) : ps) = do
  rec_uncovered <- mapOutVecBag (p:) <$> alg_uncovered (guards, us) ps
  let u_uncovered = (guards, (PmLitCon [lit]) : us)
  return $ u_uncovered `consBag` rec_uncovered

-- give-up
alg_uncovered _ _ = give_up

-- -----------------------------------------------------------------------
-- | Given an uncovered value vector and a clause, compute the covered set of
-- the clause. We represent it as a set but it is always empty or a singleton.
alg_covers :: OutVec -> InVec -> PmM Covered

-- empty
alg_covers (guards,[]) [] = return $ unitBag (guards, [])

-- any-var
alg_covers (guards, u : us) ((PmVarPat _var) : ps)
  = mapOutVecBag (u:) <$> alg_covers (guards, us) ps

-- con-con
alg_covers (guards, (PmConPat con1 ps1) : us) ((PmConPat con2 ps2) : ps)
  | con1 == con2 = mapOutVecBag (zip_con con1) <$> alg_covers (guards, ps1 ++ us) (ps2 ++ ps)
  | otherwise    = return emptyBag

-- var-con
alg_covers (guards, (PmVarPat _var):us) vec@((PmConPat con _) : _) = do
  con_pat <- mkConFull con
  alg_covers (guards, con_pat : us) vec

-- any-guard
alg_covers (guards, us) ((PmGuardPat _) : ps) = alg_covers (guards, us) ps -- actually this is an `and` operation be we never check guard on cov

-- lit-lit
alg_covers (guards, u@(PmLitPat lit) : us) ((PmLitPat lit') : ps)
  | lit /= lit' = return emptyBag
  | otherwise   = mapOutVecBag (u:) <$> alg_covers (guards, us) ps

-- nlit-lit
alg_covers (guards, u@(PmLitCon ls) : us) ((PmLitPat lit) : ps)
  | lit `elem` ls = return emptyBag
  | otherwise     = mapOutVecBag (u:) <$> alg_covers (guards, us) ps

-- var-lit
alg_covers (guards, (PmVarPat _) : us) (p@(PmLitPat _) : ps)
  = mapOutVecBag (p:) <$> alg_covers (guards, us) ps

-- give-up
alg_covers _ _ = give_up

{-
%************************************************************************
%*                                                                      *
\subsection{Typing phase}
%*                                                                      *
%************************************************************************
-}

-- -----------------------------------------------------------------------
-- | Interface to the solver
-- This is a hole for a contradiction checker. The actual type must be
-- (Bag EvVar, PmGuard) -> Bool. It should check whether are satisfiable both:
--  * The type constraints
--  * THe term constraints
isSatisfiable :: Bag EvVar -> PmM Bool
isSatisfiable evs
  = do { ((_warns, errs), res) <- initTcDsForSolver $ tcCheckSatisfiability evs
       ; case res of
            Just sat -> return sat
            Nothing  -> pprPanic "isSatisfiable" (vcat $ pprErrMsgBagWithLoc errs) }

checkTyPmPat :: PmPat Id -> Type -> PmM (Bag EvVar) -- check a type and a set of constraints
checkTyPmPat (PmGuardPat  _) _ = panic "checkTyPmPat: PmGuardPat"
checkTyPmPat (PmVarPat {})   _ = return emptyBag
checkTyPmPat (PmLitPat {})   _ = return emptyBag
checkTyPmPat (PmLitCon {})   _ = return emptyBag
checkTyPmPat (PmConPat con args) res_ty = do
  let (univ_tvs, ex_tvs, eq_spec, thetas, arg_tys, dc_res_ty) = dataConFullSig con
      data_tc = dataConTyCon con   -- The representation TyCon
      mb_tc_args = case splitTyConApp_maybe res_ty of
                     Nothing -> Nothing
                     Just (res_tc, res_tc_tys)
                       | Just (fam_tc, fam_args, _) <- tyConFamInstSig_maybe data_tc
                       , let fam_tc_tvs = tyConTyVars fam_tc
                       -> ASSERT( res_tc == fam_tc )
                          case tcMatchTys (mkVarSet fam_tc_tvs) fam_args res_tc_tys of
                            Just fam_subst -> Just (map (substTyVar fam_subst) fam_tc_tvs)
                            Nothing        -> Nothing
                       | otherwise
                       -> ASSERT( res_tc == data_tc ) Just res_tc_tys

  loc <- getSrcSpanDs
  (subst, res_eq) <- case mb_tc_args of
             Nothing  -> -- The context type doesn't have a type constructor at the head.
                         -- so generate an equality.  But this doesn't really work if there
                         -- are kind variables involved
                         do (subst, _) <- genInstSkolTyVars loc univ_tvs
                            res_eq <- newEqPmM (substTy subst dc_res_ty) res_ty
                            return (subst, unitBag res_eq)
             Just tys -> return (zipTopTvSubst univ_tvs tys, emptyBag)

  (subst, _) <- genInstSkolTyVarsX loc subst ex_tvs
  arg_cs     <- checkTyPmPats args (substTys subst arg_tys)
  theta_cs   <- mapM (nameType "varcon") $
                substTheta subst (eqSpecPreds eq_spec ++ thetas)

  return (listToBag theta_cs `unionBags` arg_cs `unionBags` res_eq)

checkTyPmPats :: [PmPat Id] -> [Type] -> PmM (Bag EvVar)
checkTyPmPats pats tys
  = do { cs <- zipWithM checkTyPmPat pats tys
       ; return (unionManyBags cs) }

genInstSkolTyVars :: SrcSpan -> [TyVar] -> PmM (TvSubst, [TyVar])
-- Precondition: tyvars should be ordered (kind vars first)
-- see Note [Kind substitution when instantiating]
-- Get the location from the monad; this is a complete freshening operation
genInstSkolTyVars loc tvs = genInstSkolTyVarsX loc emptyTvSubst tvs

-- -----------------------------------------------------------------------
-- | Given a signature sig and an output vector, check whether the vector's type
-- can match the signature
wt :: [Type] -> OutVec -> PmM Bool
wt sig (_, vec)
  | length sig == length vec = do
      cs     <- checkTyPmPats vec sig
      env_cs <- getDictsDs
      isSatisfiable (cs `unionBags` env_cs)
  | otherwise = pprPanic "wt: length mismatch:" (ppr sig $$ ppr vec)

{-
%************************************************************************
%*                                                                      *
\subsection{Misc. (Smart constructors, helper functions, etc.)}
%*                                                                      *
%************************************************************************
-}

-- -----------------------------------------------------------------------
-- | Guards

guardFails :: PmGuard
guardFails = CanFail

guardDoesntFail :: PmGuard
guardDoesntFail = CantFail

impliesGuard :: PmGuard -> PmGuard -> Bool
impliesGuard _ CanFail  = False -- conservative
impliesGuard _ CantFail = True

forcesGuard :: PmGuard -> Bool
forcesGuard CantFail = False
forcesGuard CanFail  = True -- conservative

-- -----------------------------------------------------------------------
-- | Translation of source patterns to PmPat Id

guardFailsPat :: PmPat Id
guardFailsPat = PmGuardPat guardFails

freshPmVar :: Type -> PmM (PmPat Id)
freshPmVar ty = do
  unique <- getUniqueM
  let occname = mkVarOccFS (fsLit (show unique))        -- we use the unique as the name (unsafe because
      name    = mkInternalName unique occname noSrcSpan -- we expose it. we need something more elegant
      idname  = mkLocalId name ty
  return (PmVarPat idname)

-- Used in all cases that we cannot handle. It generates a fresh variable
-- that has the same type as the given pattern and adds a guard next to it
unhandled_case :: Pat Id -> PmM [PmPat Id]
unhandled_case pat = do
  var_pat <- varFromPat pat
  return [var_pat, guardFailsPat]

-- Generate a variable from the initial pattern
-- that has the same type as the given
varFromPat :: Pat Id -> PmM (PmPat Id)
varFromPat = freshPmVar . hsPatType

-- -----------------------------------------------------------------------
-- | Types and constraints

newEqPmM :: Type -> Type -> PmM EvVar
newEqPmM ty1 ty2 = do
  unique <- getUniqueM
  let name = mkSystemName unique (mkVarOccFS (fsLit "pmcobox"))
  return $ newEvVar name (mkTcEqPred ty1 ty2)

nameType :: String -> Type -> PmM EvVar
nameType name ty = do
  unique <- getUniqueM
  let occname = mkVarOccFS (fsLit (name++"_"++show unique))
  return $ newEvVar (mkInternalName unique occname noSrcSpan) ty

newEvVar :: Name -> Type -> EvVar
newEvVar name ty = mkLocalId name (toTcType ty)

-- -----------------------------------------------------------------------
-- | Other utility functions for main check

-- (mkConFull K) makes a fresh pattern for K, thus  (K ex1 ex2 d1 d2 x1 x2 x3)
mkConFull :: DataCon -> PmM (PmPat Id)
mkConFull con = PmConPat con <$> mapM freshPmVar (dataConOrigArgTys con) -- We need the type just to create the variable name

-- Get all constructors in the family (including given)
allConstructors :: DataCon -> [DataCon]
allConstructors = tyConDataCons . dataConTyCon

-- Fold the arguments back to the constructor:
-- (K p1 .. pn) q1 .. qn         ===> p1 .. pn q1 .. qn     (unfolding)
-- zip_con K (p1 .. pn q1 .. qn) ===> (K p1 .. pn) q1 .. qn (folding)
zip_con :: DataCon -> [PmPat id] -> [PmPat id]
zip_con con pats = (PmConPat con con_pats) : rest_pats
  where -- THIS HAS A PROBLEM. WE HAVE TO BE MORE SURE ABOUT THE CONSTRAINTS WE ARE GENERATING
    (con_pats, rest_pats) = splitAtList (dataConOrigArgTys con) pats

mapOutVecBag :: ([PmPat Id] -> [PmPat Id]) -> Bag OutVec -> Bag OutVec
mapOutVecBag f bag = mapBag (\(guards, vec) -> (guards, f vec)) bag

-- See Note [Pattern match check give up]
give_up :: PmM a
give_up = failM

{-
%************************************************************************
%*                                                                      *
\subsection{Pretty Printing}
%*                                                                      *
%************************************************************************
-}

pprUncovered :: OutVec -> SDoc
pprUncovered = pprOutVec

-- Needed only for missing. Inaccessibles and redundants are handled already.
pprOutVec :: OutVec -> SDoc
pprOutVec (_, []  ) = panic "pprOutVec: empty vector"
pprOutVec (_, [p] ) = ppr p
pprOutVec (_, pats) = pprWithParens pats

pprWithParens :: (OutputableBndr id) => [PmPat id] -> SDoc
pprWithParens pats = sep (map paren_if_needed pats)
  where paren_if_needed p
          | PmConPat _ args <- p
          , not (null args) = parens (ppr p)
          | otherwise       = ppr p

-- | Pretty print list [1,2,3] as the set {1,2,3}
pprSet :: Outputable id => [id] -> SDoc
pprSet lits = braces $ sep $ punctuate comma $ map ppr lits

instance (OutputableBndr id) => Outputable (PmLit id) where
  ppr (PmLit lit)      = pmPprHsLit lit -- don't use just ppr to avoid all the hashes
  ppr (PmOLit l False) = ppr l
  ppr (PmOLit l True ) = char '-' <> ppr l

-- We do not need the (OutputableBndr id, Outputable id) because we print all
-- variables as wildcards at the end so we do not really care about them.
instance (OutputableBndr id) => Outputable (PmPat id) where
  ppr (PmGuardPat _)      = panic "ppr: PmPat id: PmGuardPat"
  ppr (PmVarPat _)        = underscore
  ppr (PmConPat con args) = sep [ppr con, pprWithParens args]
  ppr (PmLitPat lit)      = ppr lit
  ppr (PmLitCon lits)     = pprSet lits

{-
Note [Pattern match check give up]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
There are some cases where we cannot perform the check. A simple example is
trac #322:
\begin{verbatim}
  f :: Maybe Int -> Int
  f 1 = 1
  f Nothing = 2
  f _ = 3
\end{verbatim}

In this case, the first line is compiled as
\begin{verbatim}
  f x | x == fromInteger 1 = 1
\end{verbatim}

To check this match, we should perform arbitrary computations at compile time
(@fromInteger 1@) which is highly undesirable. Hence, we simply give up by
returning a @Nothing@.
-}




-- ----------------------------------------------------------------------------
-- | Rewrite the whole thing

-- | A pattern matching constraint may either be
--   * A term-level constraint: always of the form: x ~= e
--   * A type-level constraint: tau ~ tau and everything else the system supports
data PmConstraint = TmConstraint Id PmExpr
                  | TyConstraint [EvVar] -- we usually add more than one

data Abstraction = P -- Pattern abstraction
                 | V -- Value   abstraction

data PmPat2 :: Abstraction -> * where
  GBindAbs :: [PmPat2 P] -> PmExpr -> PmPat2 P   -- Guard: P <- e (strict by default) Instead of a single P use a list [AsPat]
  ConAbs   :: DataCon -> [PmPat2 abs] -> PmPat2 abs -- Constructor: K ps
  VarAbs   :: Id -> PmPat2 abs                      -- Variable: x

type ValAbs     = PmPat2 V -- Either ConAbs or VarAbs (No Guards in it)
type PatAbs     = PmPat2 P -- All possible forms
type PatternVec = [PatAbs] -- Just a type synonym for pattern vectors ps

data ValSetAbs
  = Empty                               -- {}
  | Union ValSetAbs ValSetAbs           -- S1 u S2
  | Singleton                           -- { |- empty |> empty }
  | Constraint [PmConstraint] ValSetAbs -- Extend Delta
  | Cons ValAbs ValSetAbs               -- map (ucon u) vs

-- ----------------------------------------------------------------------------
-- | Pretty printing

instance Outputable PmConstraint where
  ppr (TmConstraint x expr) = ppr x <+> equals <+> ppr expr
  ppr (TyConstraint theta)  = pprSet (map idType theta)

instance Outputable (PmPat2 abs) where
  ppr (GBindAbs pats expr) = ppr pats <+> ptext (sLit "<-") <+> ppr expr
  ppr (ConAbs con args)    = sep [ppr con, pprWithParens2 args]
  ppr (VarAbs x)           = ppr x

instance Outputable ValSetAbs where
  ppr = pprValSetAbs -- braces $ vcat $ map ppr $ valSetAbsToList vsa

pprWithParens2 :: [PmPat2 abs] -> SDoc
pprWithParens2 pats = sep (map paren_if_needed pats)
  where paren_if_needed p | ConAbs _ args <- p, not (null args) = parens (ppr p)
                          | GBindAbs ps _ <- p, not (null ps)   = parens (ppr p)
                          | otherwise = ppr p

pprValSetAbs :: ValSetAbs -> SDoc
pprValSetAbs vsa
  = add_header $ map (\(vec, cs) ->
      let (ty_cs, tm_cs) = splitConstraints cs
      in  hang (ptext (sLit "vector:") <+> ppr vec) 2 (  ptext (sLit "type_cs :") <+> ppr_ty_cs ty_cs
                                                      $$ ptext (sLit "term_cs :") <+> ppr_tm_cs tm_cs
                                                      $$ ptext (sLit "residual:") <+> tmEqSolvePrint tm_cs ))
               $ vsa_as_list
  where
    vsa_as_list = valSetAbsToList vsa
    add_header  = hang (ptext (sLit "Set:")) 2 . vcat
    ppr_tm_cs   = pprWithCommas (\(x, e) -> ppr x <+> equals <+> ppr e)
    ppr_ty_cs   = pprSet . map idType

valSetAbsToList :: ValSetAbs -> [([ValAbs],[PmConstraint])]
valSetAbsToList Empty               = []
valSetAbsToList (Union vsa1 vsa2)   = valSetAbsToList vsa1 ++ valSetAbsToList vsa2
valSetAbsToList Singleton           = [([],[])]
valSetAbsToList (Constraint cs vsa) = [(vs, cs ++ cs') | (vs, cs') <- valSetAbsToList vsa]
valSetAbsToList (Cons va vsa)       = [(va:vs, cs) | (vs, cs) <- valSetAbsToList vsa]

splitConstraints :: [PmConstraint] -> ([EvVar], [(Id, PmExpr)])
splitConstraints [] = ([],[])
splitConstraints (c : rest)
  = case c of
      TyConstraint cs  -> (cs ++ ty_cs, tm_cs)
      TmConstraint x e -> (ty_cs, (x,e):tm_cs)
  where
    (ty_cs, tm_cs) = splitConstraints rest

-- -----------------------------------------------------------------------
-- | Transform a Pat Id into a list of (PmPat Id) -- Note [Translation to PmPat]

translatePat :: UniqSupply -> Pat Id -> PatternVec
translatePat usupply pat = case pat of
  WildPat ty         -> [mkPmVar usupply ty]
  VarPat  id         -> [VarAbs id]
  ParPat p           -> translatePat usupply (unLoc p)
  LazyPat p          -> translatePat usupply (unLoc p) -- COMEHERE: We ignore laziness   for now
  BangPat p          -> translatePat usupply (unLoc p) -- COMEHERE: We ignore strictness for now
  AsPat lid p ->
    let ps  = translatePat usupply (unLoc p)
        idp = VarAbs (unLoc lid)
        g   = GBindAbs ps (PmExprVar (unLoc lid))
    in  [idp, g]
  SigPatOut p ty     -> translatePat usupply (unLoc p) -- TODO: Use the signature?
  CoPat wrapper p ty -> translatePat usupply p         -- TODO: Check if we need the coercion
  NPlusKPat n k ge minus ->
    let (xp, xe) = mkPmId2Forms usupply (idType (unLoc n))
        ke = noLoc (HsOverLit k)               -- k as located expression
        g1 = GBindAbs [ConAbs trueDataCon []] $ PmExprOther $ OpApp xe (noLoc ge)    no_fixity ke -- True <- (x >= k)
        g2 = GBindAbs [VarAbs (unLoc n)]      $ PmExprOther $ OpApp xe (noLoc minus) no_fixity ke -- n    <- (x -  k)
    in  [xp, g1, g2]

  ViewPat lexpr lpat arg_ty ->
    let (usupply1, usupply2) = splitUniqSupply usupply

        (xp, xe) = mkPmId2Forms usupply1 arg_ty
        ps = translatePat usupply2 (unLoc lpat) -- p translated recursively

        g  = GBindAbs ps $ PmExprOther $ HsApp lexpr xe -- p <- f x
    in  [xp,g]

  ListPat lpats elem_ty (Just (pat_ty, to_list)) ->
    let (usupply1, usupply2) = splitUniqSupply usupply

        (xp, xe) = mkPmId2Forms usupply1 (hsPatType pat)
        ps = translatePats usupply2 (map unLoc lpats) -- list as value abstraction

        g  = GBindAbs (concat ps) $ PmExprOther $ HsApp (noLoc to_list) xe -- [...] <- toList x
    in  [xp,g]

  ConPatOut { pat_con = L _ (PatSynCon _) } -> -- CHECKME: Is there a way to unfold this into a normal pattern?
    [mkPmVar usupply (hsPatType pat)]

  ConPatOut { pat_con = L _ (RealDataCon con), pat_args = ps } ->
    [ConAbs con (translateConPats usupply con ps)]

  NPat lit mb_neg eq ->
    let var   = mkPmId usupply (hsPatType pat)
        olit  | Just _ <- mb_neg = PmExprNeg  lit -- negated literal
              | otherwise        = PmExprOLit lit -- non-negated literal
        guard = eqTrueExpr (PmExprEq (PmExprVar var) olit)
    in  [VarAbs var, guard]

  LitPat lit ->
    let var   = mkPmId usupply (hsPatType pat)
        guard = eqTrueExpr $ PmExprEq (PmExprVar var) (PmExprLit lit)
    in  [VarAbs var, guard]

  ListPat ps ty Nothing ->
    let tidy_ps       = translatePats usupply (map unLoc ps)
        mkListPat x y = [ConAbs consDataCon (x++y)]
    in  foldr mkListPat [ConAbs nilDataCon []] tidy_ps

  PArrPat ps tys ->
    let tidy_ps  = translatePats usupply (map unLoc ps)
        fake_con = parrFakeCon (length ps)
    in  [ConAbs fake_con (concat tidy_ps)]

  TuplePat ps boxity tys ->
    let tidy_ps   = translatePats usupply (map unLoc ps)
        tuple_con = tupleCon (boxityNormalTupleSort boxity) (length ps)
    in  [ConAbs tuple_con (concat tidy_ps)]

  -- --------------------------------------------------------------------------
  -- Not supposed to happen
  ConPatIn {}      -> panic "Check.translatePat: ConPatIn"
  SplicePat {}     -> panic "Check.translatePat: SplicePat"
  QuasiQuotePat {} -> panic "Check.translatePat: QuasiQuotePat"
  SigPatIn {}      -> panic "Check.translatePat: SigPatIn"

eqTrueExpr :: PmExpr -> PatAbs
eqTrueExpr expr = GBindAbs [ConAbs trueDataCon []] expr

-- CHECKME: Can we retrieve the fixity from the operator name?
no_fixity :: a
no_fixity = panic "Check: no fixity"

translatePats :: UniqSupply -> [Pat Id] -> [PatternVec] -- Do not concatenate them (sometimes we need them separately)
translatePats usupply pats = map (uncurry translatePat) uniqs_pats
  where uniqs_pats = listSplitUniqSupply usupply `zip` pats

-- -----------------------------------------------------------------------
-- Temporary function
translateEqnInfo :: UniqSupply -> EquationInfo -> PatternVec
translateEqnInfo usupply (EqnInfo { eqn_pats = ps }) = concat $ translatePats usupply ps
-- -----------------------------------------------------------------------

translateConPats :: UniqSupply -> DataCon -> HsConPatDetails Id -> PatternVec
translateConPats usupply _ (PrefixCon ps)   = concat (translatePats usupply (map unLoc ps))
translateConPats usupply _ (InfixCon p1 p2) = concat (translatePats usupply (map unLoc [p1,p2]))
translateConPats usupply c (RecCon (HsRecFields fs _))
  | null fs   = map (uncurry mkPmVar) $ listSplitUniqSupply usupply `zip` dataConOrigArgTys c
  | otherwise = concat (translatePats usupply (map (unLoc . snd) all_pats))
  where
    -- TODO: The functions below are ugly and they do not care much about types too
    field_pats = map (\lbl -> (lbl, noLoc (WildPat (dataConFieldType c lbl)))) (dataConFieldLabels c)
    all_pats   = foldr (\(L _ (HsRecField id p _)) acc -> insertNm (getName (unLoc id)) p acc)
                       field_pats fs

    insertNm nm p [] = [(nm,p)]
    insertNm nm p (x@(n,_):xs)
      | nm == n    = (nm,p):xs
      | otherwise  = x : insertNm nm p xs

mkPmVar :: UniqSupply -> Type -> PmPat2 abs
mkPmVar usupply ty = VarAbs (mkPmId usupply ty)

mkPmId :: UniqSupply -> Type -> Id
mkPmId usupply ty = mkLocalId name ty
  where
    unique  = uniqFromSupply usupply
    occname = mkVarOccFS (fsLit (show unique))
    name    = mkInternalName unique occname noSrcSpan

-- Generate a *fresh* Id using the given UniqSupply and Type. We often need it
-- in 2 different forms: Variable Abstraction and Variable Expression
mkPmId2Forms :: UniqSupply -> Type -> (PmPat2 abs, LHsExpr Id)
mkPmId2Forms usupply ty = (VarAbs x, noLoc (HsVar x))
  where x = mkPmId usupply ty

-- ----------------------------------------------------------------------------
-- | Utility function `tailValSetAbs' and `wrapK'

tailValSetAbs :: ValSetAbs -> ValSetAbs
tailValSetAbs Empty               = Empty
tailValSetAbs Singleton           = panic "tailValSetAbs: Singleton"
tailValSetAbs (Union vsa1 vsa2)   = tailValSetAbs vsa1 `unionValSetAbs` tailValSetAbs vsa2
tailValSetAbs (Constraint cs vsa) = cs `addConstraints` tailValSetAbs vsa
tailValSetAbs (Cons _ vsa)        = vsa -- actual work

wrapK :: DataCon -> ValSetAbs -> ValSetAbs
wrapK con = wrapK_aux (dataConSourceArity con) emptylist
  where
    wrapK_aux :: Int -> DList ValAbs -> ValSetAbs -> ValSetAbs
    wrapK_aux _ _    Empty               = Empty
    wrapK_aux 0 args vsa                 = ConAbs con (toList args) `consValSetAbs` vsa
    wrapK_aux _ _    Singleton           = panic "wrapK: Singleton"
    wrapK_aux n args (Cons vs vsa)       = wrapK_aux (n-1) (args `snoc` vs) vsa
    wrapK_aux n args (Constraint cs vsa) = cs `addConstraints` wrapK_aux n args vsa
    wrapK_aux n args (Union vsa1 vsa2)   = wrapK_aux n args vsa1 `unionValSetAbs` wrapK_aux n args vsa2

-- ----------------------------------------------------------------------------
-- | Some difference lists stuff for efficiency

newtype DList a = DL { unDL :: [a] -> [a] }

toList :: DList a -> [a]
toList = ($[]) . unDL
{-# INLINE toList #-}

emptylist :: DList a
emptylist = DL id
{-# INLINE emptylist #-}

infixl `snoc`
snoc :: DList a -> a -> DList a
snoc xs x = DL (unDL xs . (x:))
{-# INLINE snoc #-}

-- ----------------------------------------------------------------------------
-- | Main function 1 (covered)

covered :: UniqSupply -> PatternVec -> ValSetAbs -> ValSetAbs

-- CEmpty (New case because of representation)
covered _usupply _vec Empty = Empty

-- CNil
covered _usupply [] Singleton = Singleton

-- Pure induction (New case because of representation)
covered usupply vec (Union vsa1 vsa2) = covered usupply1 vec vsa1 `unionValSetAbs` covered usupply2 vec vsa2
  where (usupply1, usupply2) = splitUniqSupply usupply

-- Pure induction (New case because of representation)
covered usupply vec (Constraint cs vsa) = cs `addConstraints` covered usupply vec vsa

-- CGuard
covered usupply (GBindAbs p e : ps) vsa
  | vsa' <- tailValSetAbs $ covered usupply2 (p++ps) (VarAbs y `consValSetAbs` vsa)
  = cs `addConstraints` vsa'
  where
    (usupply1, usupply2) = splitUniqSupply usupply
    y  = mkPmId usupply1 anyTy -- CHECKME: Which type to use?
    cs = [TmConstraint y e]

-- CVar
covered usupply (VarAbs x : ps) (Cons va vsa)
  = va `consValSetAbs` (cs `addConstraints` covered usupply ps vsa)
  where cs = [TmConstraint x (valAbsToPmExpr va)]

-- CConCon
covered usupply (ConAbs c1 args1 : ps) (Cons (ConAbs c2 args2) vsa)
  | c1 /= c2  = Empty
  | otherwise = wrapK c1 (covered usupply (args1 ++ ps) (foldr consValSetAbs vsa args2))

-- CConVar
covered usupply (ConAbs con args : ps) (Cons (VarAbs x) vsa)
  = covered usupply2 (ConAbs con args : ps) (con_abs `consValSetAbs` (all_cs `addConstraints` vsa))
  where
    (usupply1, usupply2) = splitUniqSupply usupply
    (con_abs, all_cs)    = mkOneConFull x usupply1 con -- if cs empty do not do it

covered _usupply (ConAbs _ _ : _) Singleton  = panic "covered: length mismatch: constructor-sing"
covered _usupply (VarAbs _   : _) Singleton  = panic "covered: length mismatch: variable-sing"
covered _usupply []               (Cons _ _) = panic "covered: length mismatch: Cons"

-- ----------------------------------------------------------------------------
-- | Main function 2 (uncovered)

uncovered :: UniqSupply -> PatternVec -> ValSetAbs -> ValSetAbs

-- UEmpty (New case because of representation)
uncovered _usupply _vec Empty = Empty

-- UNil
uncovered _usupply [] Singleton = Empty

-- Pure induction (New case because of representation)
uncovered usupply vec (Union vsa1 vsa2) = uncovered usupply1 vec vsa1 `unionValSetAbs` uncovered usupply2 vec vsa2
  where (usupply1, usupply2) = splitUniqSupply usupply

-- Pure induction (New case because of representation)
uncovered usupply vec (Constraint cs vsa) = cs `addConstraints` uncovered usupply vec vsa

-- UGuard
uncovered usupply (GBindAbs p e : ps) vsa
  = cs `addConstraints` (tailValSetAbs $ uncovered usupply2 (p++ps) (VarAbs y `consValSetAbs` vsa))
  where
    (usupply1, usupply2) = splitUniqSupply usupply
    y  = mkPmId usupply1 anyTy -- CHECKME: Which type to use?
    cs = [TmConstraint y e]

-- UVar
uncovered usupply (VarAbs x : ps) (Cons va vsa)
  = va `consValSetAbs` (cs `addConstraints` uncovered usupply ps vsa)
  where cs = [TmConstraint x (valAbsToPmExpr va)]

-- UConCon
uncovered usupply (ConAbs c1 args1 : ps) (Cons (ConAbs c2 args2) vsa)
  | c1 /= c2  = ConAbs c2 args2 `consValSetAbs` vsa
  | otherwise = wrapK c1 (uncovered usupply (args1 ++ ps) (foldr consValSetAbs vsa args2))

-- UConVar
uncovered usupply (ConAbs con args : ps) (Cons (VarAbs x) vsa)
  = uncovered usupply2 (ConAbs con args : ps) inst_vsa -- instantiated vsa [x \mapsto K_j ys]
  where
    -- Some more uniqSupplies
    (usupply1, usupply2) = splitUniqSupply usupply

    -- Unfold the variable to all possible constructor patterns
    uniqs_cons = listSplitUniqSupply usupply1 `zip` allConstructors con
    cons_cs    = map (uncurry (mkOneConFull x)) uniqs_cons
    add_one (va,cs) valset = valset `unionValSetAbs` (va `consValSetAbs` (cs `addConstraints` vsa))
    inst_vsa   = foldr add_one Empty cons_cs

uncovered _usupply (ConAbs _ _ : _) Singleton  = panic "uncovered: length mismatch: constructor-sing"
uncovered _usupply (VarAbs _   : _) Singleton  = panic "uncovered: length mismatch: variable-sing"
uncovered _usupply []               (Cons _ _) = panic "uncovered: length mismatch: Cons"

mkOneConFull :: Id -> UniqSupply -> DataCon -> (ValAbs, [PmConstraint])
mkOneConFull x usupply con = (con_abs, all_cs)
  where
    -- Some more uniqSupplies
    (usupply1, usupply') = splitUniqSupply usupply
    (usupply2, usupply3) = splitUniqSupply usupply'

    -- Instantiate variable with the approproate constructor pattern
    (_tvs, qs, _arg_tys, res_ty) = dataConSig con -- take the constructor apart
    con_abs = mkConFull2 usupply1 con -- (Ki ys), ys fresh

    -- All generated/collected constraints
    ty_eq_ct = TyConstraint [newEqPmM2 usupply2 (idType x) res_ty] -- type_eq: tau_x ~ tau (result type of the constructor)
    tm_eq_ct = TmConstraint x (valAbsToPmExpr con_abs)             -- term_eq: x ~ K ys
    uniqs_cs = listSplitUniqSupply usupply3 `zip` qs
    thetas   = map (uncurry (nameType2 "cconvar")) uniqs_cs        -- constructors_thetas: the Qs from K's sig
    all_cs   = [tm_eq_ct, ty_eq_ct, TyConstraint thetas]           -- all constraints

-- ----------------------------------------------------------------------------
-- | Main function 3 (divergent)

-- Since there is so much repetition, it may be
-- better to merge the three functions after all

-- ----------------------------------------------------------------------------
-- | Some more utility functions (COMEHERE: Remove 2 from their name)

mkConFull2 :: UniqSupply -> DataCon -> ValAbs
mkConFull2 usupply con = ConAbs con args
  where
    uniqs_tys = listSplitUniqSupply usupply `zip` dataConOrigArgTys con
    args      = map (uncurry mkPmVar) uniqs_tys

newEqPmM2 :: UniqSupply -> Type -> Type -> EvVar
newEqPmM2 usupply ty1 ty2 = newEvVar name (mkTcEqPred ty1 ty2)
  where
    unique = uniqFromSupply usupply
    name   = mkSystemName unique (mkVarOccFS (fsLit "pmcobox"))

nameType2 :: String -> UniqSupply -> Type -> EvVar
nameType2 name usupply ty = newEvVar idname ty
  where
    unique  = uniqFromSupply usupply
    occname = mkVarOccFS (fsLit (name++"_"++show unique))
    idname  = mkInternalName unique occname noSrcSpan

valAbsToPmExpr :: ValAbs -> PmExpr
valAbsToPmExpr (VarAbs x)    = PmExprVar x
valAbsToPmExpr (ConAbs c ps) = PmExprCon c (map valAbsToPmExpr ps)

-- ----------------------------------------------------------------------------
-- | Smart constructors
-- NB: The only representation of an empty value set is `Empty'

addConstraints :: [PmConstraint] -> ValSetAbs -> ValSetAbs
addConstraints _cs Empty                = Empty
addConstraints cs1 (Constraint cs2 vsa) = Constraint (cs1++cs2) vsa -- careful about associativity
addConstraints cs  other_vsa            = Constraint cs other_vsa

unionValSetAbs :: ValSetAbs -> ValSetAbs -> ValSetAbs
unionValSetAbs Empty vsa = vsa
unionValSetAbs vsa Empty = vsa
unionValSetAbs vsa1 vsa2 = Union vsa1 vsa2

consValSetAbs :: ValAbs -> ValSetAbs -> ValSetAbs
consValSetAbs _ Empty = Empty
consValSetAbs va vsa  = Cons va vsa

-- | Expressions the solver supports (It should have been (HsExpr Id) but
-- we cannot handle all of them, so we lift it to PmExpr instead.
data PmExpr = PmExprVar   Id
            | PmExprCon   DataCon [PmExpr]
            | PmExprLit   HsLit
            | PmExprOLit  (HsOverLit Id)
            | PmExprNeg   (HsOverLit Id) -- Syntactic negation
            | PmExprEq    PmExpr PmExpr  -- Syntactic equality
            | PmExprOther (HsExpr Id)    -- NOTE [PmExprOther in PmExpr]

-- ----------------------------------------------------------------------------
-- | Pretty printing

instance Outputable PmExpr where
  ppr (PmExprVar x)    = ppr x
  ppr (PmExprCon c es) = sep (ppr c : map parenIfNeeded es)
  ppr (PmExprLit  l)   = pmPprHsLit l -- don't use just ppr to avoid all the hashes
  ppr (PmExprOLit l)   = ppr l
  ppr (PmExprNeg  l)   = char '-' <> ppr l
  ppr (PmExprEq e1 e2) = parens (ppr e1 <+> equals <+> ppr e2)
  ppr (PmExprOther e)  = braces (ppr e) -- Just print it so that we know

parenIfNeeded :: PmExpr -> SDoc
parenIfNeeded e =
  case e of
    PmExprNeg _   -> parens (ppr e)
    PmExprCon _ es | null es   -> ppr e
                   | otherwise -> parens (ppr e)
    _other_expr   -> ppr e

{-
%************************************************************************
%*                                                                      *
\subsection{The term eqality oracle}
%*                                                                      *
%************************************************************************

-- NOTE [Term oracle strategy]

Because of the incremental nature of the algorithm, initially all constraints
are shallow and most of them are simple equalities between variables. In
general, even if we start only with equalities of the form (x ~ e), the oracle
distinguishes between equalities of 3 different forms:

  * Variable equalities (VE) of the form (x ~ y)
  * Simple   equalities (SE) of the form (x ~ e)
  * Complex  equalities (CE) of the form (e ~ e')

The overall strategy works in 2 phases:

A. Preperation Phase
====================
1) Partition initial set into VE and 'actual simples' SE (partitionSimple).
2) Solve VE (solveVarEqs) and apply the resulting substitution in SE.
3) Repeatedly apply [x |-> e] to SE, as long as a simple equality (x ~ e)
   exists in it (eliminateSimples). The result is a set of 'actual' complex
   equalities CE.

Steps (1),(2),(3) are all performed by `prepComplexEq' on CE, which is the
most general form of equality.

B. Solving Phase
================
1) Try to simplify the constraints by means of flattening, evaluation of
   expressions etc. (simplifyComplexEqs).
2) If some simplification happens, prepare the constraints (prepComplexEq) and
   repeat the Solving Phase.

-}

-- ----------------------------------------------------------------------------
-- | Oracle Types

-- | All different kinds of term equalities.
type VarEq     = (Id, Id)
type SimpleEq  = (Id, PmExpr) -- We always use this orientation
type ComplexEq = (PmExpr, PmExpr)

-- | The oracle will try and solve the wanted term constraints. If there is no
-- problem we get back a list of residual constraints. There are 2 types of
-- falures:
--   * Just eq: The set of constraints is non-satisfiable. The eq is evidence
--     (one of the possibly many) of this non-satisfiability.
--   * Nothing: The constraints gave rise to a (well-typed) constraint of the
--     form (K ps ~ lit), which actually is equivalent to (K ps ~ from lit),
--     where `from' is the respective overloaded function (fromInteger, etc.)
--     By default we do not unfold functions (not currently, that it) so the
--     oracle gives up (See trac #322).
type Failure = Maybe ComplexEq

-- | The oracle monad.
type TmOracleM a = Except Failure a

-- ----------------------------------------------------------------------------
-- | Oracle utils

-- | Split a set of simple equalities (of the form x ~ expr) into equalities
-- between variables only (x ~ y) and the rest (x ~ expr, where expr not a var)
partitionSimple :: [SimpleEq] -> ([VarEq], [SimpleEq])
partitionSimple in_cs = foldr select ([],[]) in_cs
  where
    select (x,e) ~(var_eqs, rest_eqs)
      | PmExprVar y <- e = ((x,y):var_eqs, rest_eqs)
      | otherwise        = (var_eqs, (x,e):rest_eqs)

-- | Split a set of complex equalities (expr ~ expr) into 3 categories:
--     * Equalities between variables (of the form (x ~ y))
--     * Simple equalities (of the form (x ~ expr, where expr not a var))
--     * The rest, complex equalities (expr ~ expr, no variable expr)
partitionComplex :: [ComplexEq] -> ([VarEq], [SimpleEq], [ComplexEq])
partitionComplex in_cs = foldr select ([],[],[]) in_cs
  where
    select eq@(e1,e2) ~(var_eqs, simpl_eqs, rest_eqs)
      | PmExprVar x <- e1 = selectSimple x e2 (var_eqs, simpl_eqs, rest_eqs)
      | PmExprVar y <- e2 = (var_eqs, (y,e1):simpl_eqs, rest_eqs)
      | otherwise         = (var_eqs, simpl_eqs, eq:rest_eqs)

    selectSimple x e ~(var_eqs, simpl_eqs, rest_eqs)
      | PmExprVar y <- e = ((x,y):var_eqs, simpl_eqs, rest_eqs)
      | otherwise        = (var_eqs, (x,e):simpl_eqs, rest_eqs)

-- See NOTE [Mixed syntax]
overloaded_error :: TmOracleM a
overloaded_error = throwE Nothing

-- Non-satisfiable set of constraints
mismatch :: ComplexEq -> TmOracleM a
mismatch eq = throwE (Just eq)

-- Expressions `True' and `False'
truePmExpr :: PmExpr
truePmExpr = PmExprCon trueDataCon []

falsePmExpr :: PmExpr
falsePmExpr = PmExprCon falseDataCon []

-- Check if a PmExpression is equal to term `True' (syntactically).
isTruePmExpr :: PmExpr -> Bool
isTruePmExpr (PmExprCon c []) = c == trueDataCon
isTruePmExpr _other_expr      = False

-- Check if a PmExpression is equal to term `False' (syntactically).
isFalsePmExpr :: PmExpr -> Bool
isFalsePmExpr (PmExprCon c []) = c == falseDataCon
isFalsePmExpr _other_expr      = False

-- ----------------------------------------------------------------------------
-- | Substitution for PmExpr

substPmExpr :: Id -> PmExpr -> PmExpr -> PmExpr
substPmExpr x e1 e =
  case e of
    PmExprVar z | x == z    -> e1
                | otherwise -> e
    PmExprCon c ps -> PmExprCon c (map (substPmExpr x e1) ps)
    PmExprEq ex ey -> PmExprEq (substPmExpr x e1 ex) (substPmExpr x e1 ey)
    _other_expr    -> e -- The rest are terminals -- we silently ignore
                        -- PmExprOther. See NOTE [PmExprOther in PmExpr]

idSubstPmExpr :: (Id -> Id) -> PmExpr -> PmExpr
idSubstPmExpr fn e =
  case e of
    PmExprVar z    -> PmExprVar (fn z)
    PmExprCon c es -> PmExprCon c (map (idSubstPmExpr fn) es)
    PmExprEq e1 e2 -> PmExprEq (idSubstPmExpr fn e1) (idSubstPmExpr fn e2)
    _other_expr    -> e -- The rest are terminals -- we silently ignore
                        -- PmExprOther. See NOTE [PmExprOther in PmExpr]

-- ----------------------------------------------------------------------------
-- | Substituting in term equalities

idSubstVarEq :: (Id -> Id) -> VarEq -> VarEq
idSubstVarEq fn (x, y) = (fn x, fn y)

idSubstSimpleEq :: (Id -> Id) -> SimpleEq -> SimpleEq
idSubstSimpleEq fn (x,e) = (fn x, idSubstPmExpr fn e)

idSubstComplexEq :: (Id -> Id) -> ComplexEq -> ComplexEq
idSubstComplexEq fn (e1,e2) = (idSubstPmExpr fn e1, idSubstPmExpr fn e2)

substComplexEq :: Id -> PmExpr -> ComplexEq -> ComplexEq
substComplexEq x e (e1, e2) = (substPmExpr x e e1, substPmExpr x e e2)

-- Faster than calling `substSimpleEq' and splitting them afterwards [USEME]
substSimpleEqs :: Id -> PmExpr -> [SimpleEq] -> ([SimpleEq], [ComplexEq])
substSimpleEqs _ _ [] = ([],[])
substSimpleEqs x e ((y,e1):rest)
  | x == y    = (simple_eqs, (e, e2):complex_eqs)
  | otherwise = ((y, e2):simple_eqs, complex_eqs)
  where (simple_eqs, complex_eqs) = substSimpleEqs x e rest
        e2 = substPmExpr x e e1

-- ----------------------------------------------------------------------------
-- | Solving equalities between variables

-- | A set of equalities between variables is always satisfiable. The result
-- is a substitution from variables to variables (TODO: The choice of the
-- variables that *survive* this operation is random. We could probably prefer
-- variables that appear in the vector?)
solveVarEq :: VarEq -> (Id -> Id)
solveVarEq (x,y)
  | x == y    = id -- trivial equality
  | otherwise = \z -> if z == y then x else z

solveVarEqs :: [VarEq] -> (Id -> Id)
solveVarEqs []       = id
solveVarEqs (eq:eqs) = solveVarEqs (map (idSubstVarEq idsubst) eqs) . idsubst
  where idsubst = solveVarEq eq

-- ----------------------------------------------------------------------------
-- | Solving simple equalities

eliminateSimples :: [SimpleEq] -> [ComplexEq] -> [ComplexEq]
eliminateSimples [] complex_eqs = complex_eqs
eliminateSimples ((x,e):eqs) complex_eqs
  = eliminateSimples simple_eqs (complex_eqs1 ++ complex_eqs2)
  where
    (simple_eqs, complex_eqs1) = substSimpleEqs x e eqs
    complex_eqs2 = map (substComplexEq x e) complex_eqs

-- ----------------------------------------------------------------------------
-- | Solving complex equalities (workhorse)

prepComplexEq :: [ComplexEq] -> [ComplexEq]
prepComplexEq []  = []
prepComplexEq eqs = eliminateSimples simple_eqs complex_eqs
  where
    (var_eqs, simple_eqs', complex_eqs') = partitionComplex eqs
    subst       = solveVarEqs var_eqs
    simple_eqs  = map (idSubstSimpleEq  subst) simple_eqs'
    complex_eqs = map (idSubstComplexEq subst) complex_eqs'

-- NB: Call only on prepped equalities (e.g. after prepComplexEq)
iterateComplex :: [ComplexEq] -> TmOracleM [ComplexEq]
iterateComplex []  = return []
iterateComplex eqs = do
  (done, eqs') <- simplifyComplexEqs eqs
  if done then iterateComplex (prepComplexEq eqs') -- did we have any progress? continue
          else return eqs'                         -- otherwise, return residual

simplifyComplexEqs :: [ComplexEq] -> TmOracleM (Bool, [ComplexEq])
simplifyComplexEqs eqs = do
  (done, new_eqs) <- mapAndUnzipM simplifyComplexEq eqs
  return (or done, concat new_eqs)

simplifyComplexEq :: ComplexEq -> TmOracleM (Bool, [ComplexEq]) -- NOTE [Termination]
simplifyComplexEq eq =
  case eq of
    -- variables
    (PmExprVar x, PmExprVar y)
      | x == y    -> return (True, [])
      | otherwise -> return (False, [eq])
    (PmExprVar _, _) -> return (False, [eq])
    (_, PmExprVar _) -> return (False, [eq])

    -- literals
    (PmExprLit l1, PmExprLit l2)
      | l1 == l2  -> return (True, [])
      | otherwise -> mismatch eq

    -- overloaded literals
    (PmExprOLit l1, PmExprOLit l2)
      | l1 == l2  -> return (True, [])
      | otherwise -> mismatch eq
    (PmExprOLit _, PmExprNeg _) -> mismatch eq
    (PmExprNeg _, PmExprOLit _) -> mismatch eq

    -- constructors
    (PmExprCon c1 es1, PmExprCon c2 es2)
      | c1 == c2  -> simplifyComplexEqs (es1 `zip` es2)
      | otherwise -> mismatch eq

    -- See NOTE [Deep equalities]
    (PmExprCon c es, PmExprEq e1 e2) -> handleDeepEq c es e1 e2
    (PmExprEq e1 e2, PmExprCon c es) -> handleDeepEq c es e1 e2

    -- Overloaded error (Double check. Some of them may need to be panics)
    (PmExprLit   _, PmExprOLit  _) -> overloaded_error
    (PmExprLit   _, PmExprNeg   _) -> overloaded_error
    (PmExprOLit  _, PmExprLit   _) -> overloaded_error
    (PmExprNeg   _, PmExprLit   _) -> overloaded_error
    (PmExprCon _ _, PmExprLit   _) -> overloaded_error
    (PmExprCon _ _, PmExprNeg   _) -> overloaded_error
    (PmExprCon _ _, PmExprOLit  _) -> overloaded_error
    (PmExprLit   _, PmExprCon _ _) -> overloaded_error
    (PmExprNeg   _, PmExprCon _ _) -> overloaded_error
    (PmExprOLit  _, PmExprCon _ _) -> overloaded_error

    _other_equality -> return (False, [eq]) -- can't simplify :(

  where
    handleDeepEq :: DataCon -> [PmExpr] -- constructor and arguments
                 -> PmExpr  -> PmExpr   -- the equality
                 -> TmOracleM (Bool, [ComplexEq]) -- NOTE [Termination]
    handleDeepEq c es e1 e2
      | c == trueDataCon = do
          (_, new) <- simplifyComplexEq (e1,e2)
          return (True, new)
      | otherwise = do
         let pmexpr = certainlyEqual e1 e2
         if isTruePmExpr pmexpr || isFalsePmExpr pmexpr
            then return (True,  [(PmExprCon c es,pmexpr)])
            else return (False, [eq])

certainlyEqual :: PmExpr -> PmExpr -> PmExpr -- NOTE [Deep equalities]
certainlyEqual e1 e2 =
  case (e1, e2) of

    -- Simple cases
    (PmExprVar   x, PmExprVar   y) -> eqVars x y        -- variables
    (PmExprLit  l1, PmExprLit  l2) -> eqLiterals  l1 l2 -- simple literals
    (PmExprOLit l1, PmExprOLit l2) -> eqOLiterals l1 l2 -- overloaded literals (same sign)
    (PmExprOLit  _, PmExprNeg   _) -> falsePmExpr       -- overloaded literals (different sign)
    (PmExprNeg   _, PmExprOLit  _) -> falsePmExpr       -- overloaded literals (different sign)

    -- Constructor case (unfold)
    (PmExprCon c1 es1, PmExprCon c2 es2) -- constructors
      | c1 == c2  -> certainlyEqualMany es1 es2
      | otherwise -> falsePmExpr

    -- Cannot be sure about the rest
    _other_equality -> expr -- Not really expressive, are we?

  where
    expr = PmExprEq e1 e2 -- reconstruct the equality from the arguments

    eqVars :: Id -> Id -> PmExpr
    eqVars x y = if x == y then truePmExpr else expr

    eqLiterals :: HsLit -> HsLit -> PmExpr
    eqLiterals l1 l2 = if l1 == l2 then truePmExpr else falsePmExpr

    eqOLiterals :: HsOverLit Id -> HsOverLit Id -> PmExpr
    eqOLiterals l1 l2 = if l1 == l2 then truePmExpr else falsePmExpr

    certainlyEqualMany :: [PmExpr] -> [PmExpr] -> PmExpr
    certainlyEqualMany es1 es2 =
      let args   = map (uncurry certainlyEqual) (es1 `zip` es2)
          result | all isTruePmExpr  args = truePmExpr
                 | any isFalsePmExpr args = falsePmExpr
                 | otherwise              = expr
      in  result

-- Just an idea: There is so much repetition, we could make
-- a class for this sort of thing. For example:
--
-- class EqCheckable a where
--   equal :: a -> a -> a -> PmExpr -- x, y and default value
--
-- we need the default only for the last instance, we can construct it for the others
--
-- instance EqCheckable Id where
--   equal x y _ = if x == y then truePmExpr else (PmExprEq (PmExprVar x) (PmExprVar y)-- Not false, variables can be unified later
--
-- instance EqCheckable HsLit where
--   equal l1 l2 _ = if l1 == l2 then truePmExpr else falsePmExpr
--
-- instance EqCheckable (HsOverLit Id) where
--   equal l1 l2 _ = if l1 == l2 then truePmExpr else falsePmExpr
--
-- instance EqCheckable PmExpr where
--   equals e1 e2 _ = certainlyEqual e1 e2 -- we know what the default is
--
-- instance EqCheckable a => EqCheckable [a] where -- certainlyEqualMany with the default expr explicitly given
--   equals es1 es2 expr =
--     let args   = map (uncurry certainlyEqual) (es1 `zip` es2)
--         result | all isTruePmExpr  args = truePmExpr
--                | any isFalsePmExpr args = falsePmExpr
--                | otherwise              = expr
--     in  result

-- ----------------------------------------------------------------------------
-- | Entry point to the solver

tmOracle :: [SimpleEq] -> Either Failure [ComplexEq]
tmOracle simple_eqs = runExcept (solveAll simple_eqs)

solveAll :: [SimpleEq] -> TmOracleM [ComplexEq]
solveAll []  = return []
solveAll eqs = iterateComplex complex_eqs
  where
    (var_eqs, simple_eqs') = partitionSimple eqs
    subst       = solveVarEqs var_eqs
    simple_eqs  = map (idSubstSimpleEq subst) simple_eqs'
    complex_eqs = eliminateSimples simple_eqs []

-- ----------------------------------------------------------------------------
-- TEMPORARY: Just to check our results
-- ----------------------------------------------------------------------------
tmEqSolvePrint :: [SimpleEq] -> SDoc
tmEqSolvePrint simple_eqs =
  case tmOracle simple_eqs of
    Left failure -> case failure of
      Just eq -> ptext (sLit "Yo, inconsistent constraint:") <+> ppr_equality eq
      Nothing -> ptext (sLit "Yo, simple/overloaded syntax")
    Right residual -> ppr_complex residual
  where
    eq_sym             = equals <> colon <> equals
    ppr_equality (x,y) = ppr x <+> eq_sym <+> ppr y
    ppr_complex        = pprWithCommas ppr_equality
-- ----------------------------------------------------------------------------


-- NOTE [Representation of substitution]
--
-- Throughout the code we use 2 different ways to represent substitutions:
--   * Substitutions from variables to variables are represented using Haskell
--     functions with type (Id -> Id).
--   * Substitutions from variables to expressions are usually passed explicitly
--     as two arguments (the Id and the PmExpr to substitute it with)
-- By convention, substitutions of the first kind are prefixed by `idSubst'
-- while the latter are prefixed simply by 'subst'.


-- NOTE [PmExprOther in PmExpr]
--
-- Data constructor `PmExprOther' lifts an (HsExpr Id) to a PmExpr. Ideally we
-- would have only (HsExpr Id) but this would be really verbose:
--    The solver is pretty naive and cannot handle many Haskell expressions.
-- Since there is no plan (for the near future) to change the solver there
-- is no need to work with the full HsExpr type (more than 45 constructors).
--
-- Functions `substPmExpr' and `idSubstPmExpr' do not substitute in HsExpr, which
-- could be a problem for a different solver. E.g:
--
-- For the following set of constraints (HsExpr in braces):
--
--   (y ~ x, y ~ z, y ~ True, y ~ False, {not y})
--
-- would be simplified (in one step using `solveVarEqs') to:
--
--   (x ~ True, x ~ False, {not y})
--
-- i.e. y is now free to be unified with anything! This is not a problem now
-- because we never inspect a PmExprOther (They always end up in residual)
-- but a more sophisticated solver may need to do so!


-- NOTE [Deep equalities]
--
-- Solving nested equalities is the most difficult part. The general strategy
-- is the following:
--
--   * Equalities of the form (True ~ (e1 ~ e2)) are transformed to just
--     (e1 ~ e2) and then treated recursively.
--
--   * Equalities of the form (False ~ (e1 ~ e2)) cannot be analyzed unless
--     we know more about the inner equality (e1 ~ e2). That's exactly what
--     `certainlyEqual' tries to do: It takes e1 and e2 and either returns
--     truePmExpr, falsePmExpr or (e1' ~ e2') in case it is uncertain. Note
--     that it is not e but rather e', since it may perform some
--     simplifications deeper.

-- NOTE [Termination]
--
-- The simplification functions return a boolean along with the results, in
-- order to keep track if some simplification happened or not. This is how
-- `solveComplex' knows when to stop looping. When no simplification happens
-- (False), we simply return the residual constraints.
--
-- SAY SOME MORE ABOUT IT: LOOP BECAUSE OF EQUALITIES THEMSELVES


