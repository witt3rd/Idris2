module TTImp.Elab.Ambiguity

import Core.Context
import Core.Core
import Core.Env
import Core.Metadata
import Core.Normalise
import Core.Unify
import Core.TT
import Core.Value

import TTImp.Elab.Check
import TTImp.Elab.Delayed
import TTImp.TTImp

import Data.Bool.Extra
import Data.List
import Data.StringMap

%default covering

export
expandAmbigName : {vars : _} ->
                  {auto c : Ref Ctxt Defs} ->
                  {auto e : Ref EST (EState vars)} ->
                  ElabMode -> NestedNames vars -> Env Term vars -> RawImp ->
                  List (FC, Maybe (Maybe Name), RawImp) ->
                  RawImp -> Maybe (Glued vars) -> Core RawImp
expandAmbigName (InLHS _) nest env orig args (IBindVar fc n) exp
    = do est <- get EST
         if UN n `elem` lhsPatVars est
            then pure $ IMustUnify fc NonLinearVar orig
            else pure $ orig
expandAmbigName mode nest env orig args (IVar fc x) exp
   = case lookup x (names nest) of
          Just _ => do log "elab.ambiguous" 10 $ "Nested " ++ show x
                       pure orig
          Nothing => do
             defs <- get Ctxt
             case defined x env of
                  Just _ =>
                    if isNil args || notLHS mode
                       then do log "elab.ambiguous" 10 $ "Defined in env " ++ show x
                               pure $ orig
                       else pure $ IMustUnify fc VarApplied orig
                  Nothing =>
                     do est <- get EST
                        fi <- fromIntegerName
                        si <- fromStringName
                        ci <- fromCharName
                        let prims = mapMaybe id [fi, si, ci]
                        let primApp = isPrimName prims x
                        case lookupUN (userNameRoot x) (unambiguousNames est) of
                          Just xr => do
                            log "elab.ambiguous" 10 $ "unambiguous: " ++ show (fst xr)
                            pure $ mkAlt primApp est xr
                          Nothing => do
                            ns <- lookupCtxtName x (gamma defs)
                            ns' <- filterM visible ns
                            case ns' of
                               [] => do log "elab.ambiguous" 10 $ "Failed to find " ++ show orig
                                        pure orig
                               [nalt] =>
                                     do log "elab.ambiguous" 10 $ "Only one " ++ show (fst nalt)
                                        pure $ mkAlt primApp est nalt
                               nalts => pure $ IAlternative fc (uniqType fi si ci x args)
                                                      (map (mkAlt primApp est) nalts)
  where
    lookupUN : Maybe String -> StringMap a -> Maybe a
    lookupUN Nothing _ = Nothing
    lookupUN (Just n) sm = lookup n sm

    visible : (Name, Int, GlobalDef) -> Core Bool
    visible (n, i, def)
        = do let NS ns x = fullname def
                 | _ => pure True
             if !(isVisible ns)
                then pure $ visibleInAny (!getNS :: !getNestedNS) (NS ns x)
                                         (visibility def)
                else pure False

    -- If there's multiple alternatives and all else fails, resort to using
    -- the primitive directly
    uniqType : Maybe Name -> Maybe Name -> Maybe Name -> Name ->
               List (FC, Maybe (Maybe Name), RawImp) -> AltType
    uniqType (Just fi) _ _ n [(_, _, IPrimVal fc (BI x))]
        = UniqueDefault (IPrimVal fc (BI x))
    uniqType _ (Just si) _ n [(_, _, IPrimVal fc (Str x))]
        = UniqueDefault (IPrimVal fc (Str x))
    uniqType _ _ (Just ci) n [(_, _, IPrimVal fc (Ch x))]
        = UniqueDefault (IPrimVal fc (Ch x))
    uniqType _ _ _ _ _ = Unique

    buildAlt : RawImp -> List (FC, Maybe (Maybe Name), RawImp) ->
               RawImp
    buildAlt f [] = f
    buildAlt f ((fc', Nothing, a) :: as)
        = buildAlt (IApp fc' f a) as
    buildAlt f ((fc', Just i, a) :: as)
        = buildAlt (IImplicitApp fc' f i a) as

    isPrimName : List Name -> Name -> Bool
    isPrimName [] fn = False
    isPrimName (p :: ps) fn
        = dropNS fn == p || isPrimName ps fn

    -- If it's not a constructor application, dot it
    wrapDot : Bool -> EState vars ->
              ElabMode -> Name -> List RawImp -> Def -> RawImp -> RawImp
    wrapDot _ _ _ _ _ (DCon _ _ _) tm = tm
    wrapDot _ _ _ _ _ (TCon _ _ _ _ _ _ _ _) tm = tm
    -- Leave primitive applications alone, because they'll be inlined
    -- before compiling the case tree
    wrapDot prim est (InLHS _) n' [arg] _ tm
       = if n' == Resolved (defining est) || prim
            then tm
            else IMustUnify fc NotConstructor tm
    wrapDot prim est (InLHS _) n' _ _ tm
       = if n' == Resolved (defining est)
            then tm
            else IMustUnify fc NotConstructor tm
    wrapDot _ _ _ _ _ _ tm = tm


    mkTerm : Bool -> EState vars -> Name -> GlobalDef -> RawImp
    mkTerm prim est n def
        = let tm = wrapDot prim est mode n (map (snd . snd) args)
                       (definition def) (buildAlt (IVar fc n) args) in
              if Macro `elem` flags def
                 then case mode of
                           InLHS _ => tm
                           _ => IRunElab fc (ICoerced fc tm)
                 else tm

    mkAlt : Bool -> EState vars -> (Name, Int, GlobalDef) -> RawImp
    mkAlt prim est (fullname, i, gdef)
        = mkTerm prim est (Resolved i) gdef

    notLHS : ElabMode -> Bool
    notLHS (InLHS _) = False
    notLHS _ = True

expandAmbigName mode nest env orig args (IApp fc f a) exp
    = expandAmbigName mode nest env orig
                      ((fc, Nothing, a) :: args) f exp
expandAmbigName mode nest env orig args (IImplicitApp fc f n a) exp
    = expandAmbigName mode nest env orig
                      ((fc, Just n, a) :: args) f exp
expandAmbigName elabmode nest env orig args tm exp
    = do log "elab.ambiguous" 10 $ "No ambiguity " ++ show orig
         pure orig

stripDelay : NF vars -> NF vars
stripDelay (NDelayed fc r t) = stripDelay t
stripDelay tm = tm

data TypeMatch = Concrete | Poly | NoMatch

Show TypeMatch where
  show Concrete = "Concrete"
  show Poly = "Poly"
  show NoMatch = "NoMatch"

mutual
  mightMatchD : {vars : _} ->
                Defs -> NF vars -> NF [] -> Core TypeMatch
  mightMatchD defs l r
      = mightMatch defs (stripDelay l) (stripDelay r)

  mightMatchArg : {vars : _} ->
                  Defs ->
                  Closure vars -> Closure [] ->
                  Core Bool
  mightMatchArg defs l r
      = pure $ case !(mightMatchD defs !(evalClosure defs l) !(evalClosure defs r)) of
             NoMatch => False
             _ => True

  mightMatchArgs : {vars : _} ->
                   Defs ->
                   List (Closure vars) -> List (Closure []) ->
                   Core Bool
  mightMatchArgs defs [] [] = pure True
  mightMatchArgs defs (x :: xs) (y :: ys)
      = do amatch <- mightMatchArg defs x y
           if amatch
              then mightMatchArgs defs xs ys
              else pure False
  mightMatchArgs _ _ _ = pure False

  mightMatch : {vars : _} ->
               Defs -> NF vars -> NF [] -> Core TypeMatch
  mightMatch defs target (NBind fc n (Pi _ _ _ _) sc)
      = mightMatchD defs target !(sc defs (toClosure defaultOpts [] (Erased fc False)))
  mightMatch defs (NTCon _ n t a args) (NTCon _ n' t' a' args')
      = if n == n'
           then do amatch <- mightMatchArgs defs args args'
                   if amatch then pure Concrete else pure NoMatch
           else pure NoMatch
  mightMatch defs (NDCon _ n t a args) (NDCon _ n' t' a' args')
      = if t == t'
           then do amatch <- mightMatchArgs defs args args'
                   if amatch then pure Concrete else pure NoMatch
           else pure NoMatch
  mightMatch defs (NPrimVal _ x) (NPrimVal _ y)
      = if x == y then pure Concrete else pure NoMatch
  mightMatch defs (NType _) (NType _) = pure Concrete
  mightMatch defs (NApp _ _ _) _ = pure Poly
  mightMatch defs (NErased _ _) _ = pure Poly
  mightMatch defs _ (NApp _ _ _) = pure Poly
  mightMatch defs _ (NErased _ _) = pure Poly
  mightMatch _ _ _ = pure NoMatch

-- Return true if the given name could return something of the given target type
couldBeName : {vars : _} ->
              Defs -> NF vars -> Name -> Core TypeMatch
couldBeName defs target n
    = case !(lookupTyExact n (gamma defs)) of
           Nothing => pure Poly -- could be a local name, don't rule it out
           Just ty => mightMatchD defs target !(nf defs [] ty)

couldBeFn : {vars : _} ->
            Defs -> NF vars -> RawImp -> Core TypeMatch
couldBeFn defs ty (IVar _ n) = couldBeName defs ty n
couldBeFn defs ty (IAlternative _ _ _) = pure Concrete
couldBeFn defs ty _ = pure Poly

-- Returns Nothing if there's no possibility the expression's type matches
-- the target type
-- Just (True, app) if it's a match on concrete return type
-- Just (False, app) if it might be a match due to being polymorphic
couldBe : {vars : _} ->
          Defs -> NF vars -> RawImp -> Core (Maybe (Bool, RawImp))
couldBe {vars} defs ty@(NTCon _ n _ _ _) app
   = case !(couldBeFn {vars} defs ty (getFn app)) of
          Concrete => pure $ Just (True, app)
          Poly => pure $ Just (False, app)
          NoMatch => pure Nothing
couldBe {vars} defs ty@(NPrimVal _ _) app
   = case !(couldBeFn {vars} defs ty (getFn app)) of
          Concrete => pure $ Just (True, app)
          Poly => pure $ Just (False, app)
          NoMatch => pure Nothing
couldBe {vars} defs ty@(NType _) app
   = case !(couldBeFn {vars} defs ty (getFn app)) of
          Concrete => pure $ Just (True, app)
          Poly => pure $ Just (False, app)
          NoMatch => pure Nothing
couldBe defs ty app = pure $ Just (False, app)


notOverloadable : Defs -> (Bool, RawImp) -> Core Bool
notOverloadable defs (True, fn) = pure True
notOverloadable defs (concrete, fn) = notOverloadableFn (getFn fn)
  where
    notOverloadableFn : RawImp -> Core Bool
    notOverloadableFn (IVar _ n)
        = do Just gdef <- lookupCtxtExact n (gamma defs)
                  | Nothing => pure True
             pure False -- If the name exists, and doesn't have a concrete type
                        -- but another possibility does, remove it from the set
                        -- no matter what
                        -- (TODO: Consider whether %allow_overloads should exist)
                        -- (not (Overloadable `elem` flags gdef))
    notOverloadableFn _ = pure True

filterCore : (a -> Core Bool) -> List a -> Core (List a)
filterCore f [] = pure []
filterCore f (x :: xs)
    = do p <- f x
         xs' <- filterCore f xs
         if p then pure (x :: xs')
              else pure xs'

pruneByType : {vars : _} ->
              {auto c : Ref Ctxt Defs} ->
              {auto u : Ref UST UState} ->
              Env Term vars -> NF vars -> List RawImp ->
              Core (List RawImp)
pruneByType env target alts
    = do defs <- get Ctxt
         matches_in <- traverse (couldBe defs (stripDelay target)) alts
         let matches = mapMaybe id matches_in
         logNF "elab.prune" 10 "Prune by" env target
         log "elab.prun" 10 (show matches)
         res <- if anyTrue (map fst matches)
                -- if there's any concrete matches, drop the non-concrete
                -- matches marked as '%allow_overloads' from the possible set
                   then do keep <- filterCore (notOverloadable defs) matches
                           log "elab.prune" 10 $ "Keep " ++ show keep
                           pure (map snd keep)
                   else pure (map snd matches)
         if isNil res
            then pure alts -- if none of them work, better to show all the errors
            else pure res

checkAmbigDepth : {auto c : Ref Ctxt Defs} ->
                  {auto e : Ref EST (EState vars)} ->
                  FC -> ElabInfo -> Core ()
checkAmbigDepth fc info
    = do max <- getAmbigLimit
         let ambs = ambigTries info
         when (length ambs > max) $
           do est <- get EST
              throw (AmbiguityTooDeep fc (Resolved (defining est)) ambs)

getName : RawImp -> Maybe Name
getName (IVar _ n) = Just n
getName (IApp _ f _) = getName f
getName (IImplicitApp _ f _ _) = getName f
getName _ = Nothing

export
addAmbig : List alts -> Maybe Name -> ElabInfo -> ElabInfo
addAmbig _ Nothing = id
addAmbig [] _ = id
addAmbig [_] _ = id
addAmbig _ (Just n) = record { ambigTries $= (n ::) }

export
checkAlternative : {vars : _} ->
                   {auto c : Ref Ctxt Defs} ->
                   {auto m : Ref MD Metadata} ->
                   {auto u : Ref UST UState} ->
                   {auto e : Ref EST (EState vars)} ->
                   RigCount -> ElabInfo ->
                   NestedNames vars -> Env Term vars ->
                   FC -> AltType -> List RawImp -> Maybe (Glued vars) ->
                   Core (Term vars, Glued vars)
checkAlternative rig elabinfo nest env fc (UniqueDefault def) alts mexpected
    = do checkAmbigDepth fc elabinfo
         expected <- maybe (do nm <- genName "altTy"
                               ty <- metaVar fc erased env nm (TType fc)
                               pure (gnf env ty))
                           pure mexpected
         let solvemode = case elabMode elabinfo of
                              InLHS c => inLHS
                              _ => inTermP False
         delayOnFailure fc rig env expected ambiguous 5 $
             \delayed =>
               do solveConstraints solvemode Normal
                  defs <- get Ctxt
                  exp <- getTerm expected

                  -- We can't just use the old NF on the second attempt,
                  -- because we might know more now, so recalculate it
                  let exp' = if delayed
                                then gnf env exp
                                else expected

                  logGlueNF "elab.ambiguous" 5 ("Ambiguous elaboration " ++ show alts ++
                               " at " ++ show fc ++
                               "\nWith default. Target type ") env exp'
                  alts' <- pruneByType env !(getNF exp') alts
                  log "elab.prun" 5 ("Pruned alts (" ++ show (length alts') ++ ") " ++
                          show alts')

                  if delayed -- use the default if there's still ambiguity
                     then try
                            (exactlyOne' False fc env
                                (map (\t =>
                                   (getName t,
                                    checkImp rig (addAmbig alts' (getName t) elabinfo)
                                             nest env t
                                             (Just exp'))) alts'))
                            (do log "elab" 5 "All failed, running default"
                                checkImp rig (addAmbig alts' (getName def) elabinfo)
                                             nest env def (Just exp'))
                     else exactlyOne' True fc env
                           (map (\t =>
                             (getName t,
                              checkImp rig (addAmbig alts' (getName t) elabinfo)
                                       nest env t (Just exp')))
                              alts')
checkAlternative rig elabinfo nest env fc uniq alts mexpected
    = do checkAmbigDepth fc elabinfo
         alts' <- maybe (Core.pure [])
                        (\exp => pruneByType env !(getNF exp) alts) mexpected
         case alts' of
           [alt] => checkImp rig elabinfo nest env alt mexpected
           _ =>
             do expected <- maybe (do nm <- genName "altTy"
                                      ty <- metaVar fc erased env nm (TType fc)
                                      pure (gnf env ty))
                                  pure mexpected
                let solvemode = case elabMode elabinfo of
                                      InLHS c => inLHS
                                      _ => inTermP False
                delayOnFailure fc rig env expected ambiguous 5 $
                     \delayed =>
                       do defs <- get Ctxt
                          exp <- getTerm expected

                          -- We can't just use the old NF on the second attempt,
                          -- because we might know more now, so recalculate it
                          let exp' = if delayed
                                        then gnf env exp
                                        else expected

                          alts' <- pruneByType env !(getNF exp') alts

                          logGlueNF "elab.ambiguous" 5 ("Ambiguous elaboration " ++ show delayed ++ " " ++
                                       show alts' ++
                                       " at " ++ show fc ++
                                       "\nTarget type ") env exp'
                          let tryall = case uniq of
                                            FirstSuccess => anyOne fc
                                            _ => exactlyOne' (not delayed) fc env
                          tryall (map (\t =>
                              (getName t,
                               do res <- checkImp rig (addAmbig alts' (getName t) elabinfo)
                                                  nest env t (Just exp')
                                  -- Do it twice for interface resolution;
                                  -- first pass gets the determining argument
                                  -- (maybe rethink this, there should be a better
                                  -- way that allows one pass)
                                  solveConstraints solvemode Normal
                                  solveConstraints solvemode Normal
                                  log "elab" 10 $ show (getName t) ++ " success"
                                  pure res)) alts')
