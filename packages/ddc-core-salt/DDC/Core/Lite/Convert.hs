
-- | Conversion of Disciple Lite to Disciple Salt.
--
module DDC.Core.Lite.Convert
        ( toSalt
        , Error(..))
where
import DDC.Core.Lite.Convert.Data
import DDC.Core.Lite.Convert.Type
import DDC.Core.Lite.Convert.Base
import DDC.Core.Salt.Convert.Init
import DDC.Core.Salt.Platform
import DDC.Core.Module
import DDC.Core.Compounds
import DDC.Core.Predicates
import DDC.Core.Exp
import DDC.Type.Compounds
import DDC.Type.Predicates
import DDC.Type.Universe
import DDC.Type.DataDef
import DDC.Type.Check.Monad              (throw, result)
import DDC.Core.Check                    (AnTEC(..))
import DDC.Type.Env                      (Env)
import qualified DDC.Core.Lite.Name      as L
import qualified DDC.Core.Salt.Runtime   as S
import qualified DDC.Core.Salt.Name      as S
import qualified DDC.Core.Salt.Compounds as S
import qualified DDC.Type.Env            as Env
import qualified Data.Map                as Map
import Control.Monad


-- | Convert a Disciple Core Lite module to Disciple Core Salt.
--
--   Case expressions on alrebraic data values are converted into ones that just
--   check the tag, while data constructors are unfolded into explicit allocation
--   and field initialization primops. 
--
--   The input module needs to be:
--      well typed,
--      fully named with no deBruijn indices,
--      have all functions defined at top-level,
--      have type annotations on every bound variable and constructor
--      a-normalised
--      If not then `Error`.
--
--   The output code contains:
--      debruijn indices.
--       these which need to be eliminated before it will pass the Salt fragment checks.
--
--   TODO: Add the alternatives that force and follow lazy thunks and indirections.
--   TODO: Expand partial and over-applications into code that explicitly builds
--         and applies thunks.
--
toSalt
        :: Show a
        => Platform                             -- ^ Platform specification.
        -> S.Config                             -- ^ Runtime configuration.
        -> DataDefs L.Name                      -- ^ Data type definitions.
        -> Env L.Name                           -- ^ Kind environment.
        -> Env L.Name                           -- ^ Type environment.
        -> Module (AnTEC a L.Name) L.Name       -- ^ Lite module to convert.
        -> Either (Error a) (Module a S.Name)   -- ^ Salt module.
toSalt platform runConfig defs kenv tenv mm
 = result $ convertM platform runConfig defs kenv tenv mm


-- Module ---------------------------------------------------------------------
convertM 
        :: Show a
        => Platform
        -> S.Config
        -> DataDefs L.Name
        -> Env L.Name
        -> Env L.Name
        -> Module (AnTEC a L.Name) L.Name 
        -> ConvertM a (Module a S.Name)

convertM pp runConfig defs kenv tenv mm
  = do  
        -- Collect up signatures of imported functions.
        tsImports'
                <- liftM Map.fromList
                $  mapM convertImportM  
                $  Map.toList
                $  moduleImportTypes mm

        -- Convert the body of the module to Salt.
        let ntsImports  = [(BName n t) | (n, (_, t)) <- Map.toList $ moduleImportTypes mm]
        let tenv'       = Env.extends ntsImports tenv
        x'              <- convertBodyX pp defs kenv tenv' $ moduleBody mm

        -- Build the output module.
        let mm_salt 
                = ModuleCore
                { moduleName           = moduleName mm
                , moduleExportKinds    = Map.empty
                , moduleExportTypes    = Map.empty
                , moduleImportKinds    = Map.empty
                , moduleImportTypes    = Map.union S.runtimeImportSigs tsImports'
                , moduleBody           = x' }

        -- If this is the 'Main' module then add code to initialise the 
        -- runtime system. This will fail if given a Main module with no
        -- 'main' function.
        mm_init <- case initRuntime runConfig mm_salt of
                        Nothing   -> throw ErrorMainHasNoMain
                        Just mm'  -> return mm'

        return $ mm_init
                

-- | Convert an import spec.
convertImportM
        :: (L.Name, (QualName L.Name, Type L.Name))
        -> ConvertM a (S.Name, (QualName S.Name, Type S.Name))

convertImportM (n, (qn, t))
 = do   n'      <- convertBindNameM n
        qn'     <- convertQualNameM qn
        t'      <- convertT t
        return  (n', (qn', t'))


-- | Convert a qualified name.
convertQualNameM
        :: QualName L.Name 
        -> ConvertM a (QualName S.Name)

convertQualNameM (QualName mn n)
 = do   n'      <- convertBindNameM n
        return  $ QualName mn n'


-- Exp -------------------------------------------------------------------------
convertBodyX 
        :: Show a 
        => Platform
        -> DataDefs L.Name 
        -> Env L.Name
        -> Env L.Name
        -> Exp (AnTEC a L.Name) L.Name 
        -> ConvertM a (Exp a S.Name)

convertBodyX pp defs kenv tenv xx
 = case xx of
        XVar _ UIx{}
         -> throw $ ErrorMalformed 
         $  "convertBodyX: can't convert program with anonymous value binders."

        XVar a u
         -> do  let a'  = annotTail a
                u'      <- convertU u
                return  $  XVar a' u'

        XCon a u
         -> do  let a'  = annotTail a
                xx'     <- convertCtor pp defs a' u
                return  xx'

        -- Keep region and data type lambdas, 
        -- but ditch the others.
        XLAM a b x
         |   (isRegionKind $ typeOfBind b)
          || (isDataKind   $ typeOfBind b)
         -> do  let a'          = annotTail a
                b'              <- convertB b

                let kenv'       = Env.extend b kenv
                x'              <- convertBodyX pp defs kenv' tenv x

                return $ XLAM a' b' x'

         | otherwise
         -> do  let kenv'       = Env.extend b kenv
                convertBodyX pp defs kenv' tenv x


        XLam a b x
         -> let tenv'   = Env.extend b tenv
            in case universeFromType1 kenv (typeOfBind b) of
                Just UniverseData    
                 -> liftM3 XLam 
                        (return $ annotTail a) 
                        (convertB b) 
                        (convertBodyX pp defs kenv tenv' x)

             Just UniverseWitness 
              -> convertBodyX pp defs x

                _  -> throw $ ErrorMalformed 
                            $ "Invalid universe for XLam binder: " ++ show b

        XApp{}
         ->     convertSimpleX pp defs xx

        XLet a (LRec bxs) x2
         -> do  let tenv'       = Env.extends (map fst bxs) tenv
                let (bs, xs)    = unzip bxs
                bs'             <- mapM convertB bs
                xs'             <- mapM (convertBodyX pp defs kenv tenv') xs
                x2'             <- convertBodyX pp defs kenv tenv' x2
                return $ XLet (annotTail a) (LRec $ zip bs' xs') x2'

        XLet a (LLet LetStrict b x1) x2
         -> do  let tenv'       = Env.extend b tenv
                b'              <- convertB b
                x1'             <- convertSimpleX pp defs x1
                x2'             <- convertBodyX   pp defs kenv tenv' x2
                return  $ XLet (annotTail a) (LLet LetStrict b' x1') x2'

        XLet _ (LLet LetLazy{} _ _) _
         -> error "DDC.Core.Lite.Convert.toSaltX: XLet lazy not handled yet"

        XLet a (LLetRegion b bs) x2
         -> do  let kenv'       = Env.extend b kenv
                b'              <- convertB b
                bs'             <- mapM convertB bs
                x2'             <- convertBodyX pp defs kenv' tenv x2
                return  $ XLet (annotTail a) (LLetRegion b' bs') x2'

        XLet _ LWithRegion{} _
         -> throw $ ErrorMalformed "LWithRegion should not appear in Lite code."


        -- Match against literal unboxed values.
        --  The branch is against the literal value itself.
        --
        --  TODO: We can't branch against float literals.
        --        Matches against float literals should be desugared into if-then-else chains.
        --        Same for string literals.
        --
        XCase (AnTEC _t _ _ a') xScrut@(XVar _ uScrut) alts
         | TCon (TyConBound (UPrim nType _) _)  <- error "Lite.convertBodyX: need environment" -- typeOfBound uScrut
         , L.NamePrimTyCon _                    <- nType
         -> do  xScrut' <- convertSimpleX pp defs xScrut
                alts'   <- mapM (convertAlt pp defs kenv tenv a' uScrut) alts
                return  $  XCase a' xScrut' alts'

        -- Match against finite algebraic data.
        --   The branch is against the constructor tag.
        XCase (AnTEC t _ _ a') x@(XVar _ uX) alts  
         -> do  x'@(XVar _ uX') <- convertSimpleX   pp defs x
                t'              <- convertT t
                alts'           <- mapM (convertAlt pp defs kenv tenv a' uX) alts

                let asDefault
                        | any isPDefault [p | AAlt p _ <- alts]   
                        = []

                        | otherwise     
                        = [AAlt PDefault (S.xFail a' t')]

                let Just tPrime = uX' `seq` error "Lite.convertBodyX: need environment" -- takePrimeRegion (typeOfBound uX')
                return  $ XCase a' (S.xGetTag a' tPrime x') 
                        $ alts' ++ asDefault

        XCase{}         -> throw $ ErrorNotNormalized ("found case expression")

        XCast _ _ x     -> convertBodyX pp defs kenv tenv x

        XType _         -> throw $ ErrorMistyped xx
        XWitness{}      -> throw $ ErrorMistyped xx


-------------------------------------------------------------------------------
-- | Convert the right of an internal let-binding.
--   The right of the binding must be straight-line code, 
--   and cannot contain case-expressions, or construct new functions.
--  
convertSimpleX
        :: Show a 
        => Platform 
        -> DataDefs L.Name
        -> Exp (AnTEC a L.Name) L.Name
        -> ConvertM a (Exp a S.Name)

convertSimpleX pp defs xx
 = case xx of

        XType{}         
         -> throw $ ErrorMalformed 
         $ "convertRValueX: XType should not appear as the right of a let-binding"

        XWitness{}
         -> throw $ ErrorMalformed 
         $ "convertRValueX: XWithess should not appear as the right of a let-binding"

        -- Primitive data constructors.
        XApp a xa xb
         | (x1, xsArgs)           <- takeXApps' xa xb
         , XCon _ (UPrim nCtor _) <- x1
         -> convertCtorAppX pp a defs nCtor xsArgs

        -- User-defined data constructors.
        XApp a xa xb
         | (x1, xsArgs)           <- takeXApps' xa xb
         , XCon _ (UName nCtor)   <- x1
         -> convertCtorAppX pp a defs nCtor xsArgs

        -- Primitive operations.
        XApp a xa xb
         | (x1, xsArgs)          <- takeXApps' xa xb
         , XVar _ UPrim{}        <- x1
         -> do  x1'     <- convertAtomX pp defs x1

                xsArgs' <- mapM (convertAtomX pp defs) xsArgs

                return $ makeXApps (annotTail a) x1' xsArgs'

        -- Function application
        -- TODO: This only works for full application. 
        --       At least check for the other cases.
        XApp (AnTEC _t _ _ a') xa xb
         | (x1, xsArgs) <- takeXApps' xa xb
         -> do  x1'     <- convertAtomX pp defs x1
                xsArgs' <- mapM (convertAtomX pp defs) xsArgs
                return  $ makeXApps a' x1' xsArgs'

        _ -> convertAtomX pp defs xx


-------------------------------------------------------------------------------
-- | Convert an atom to Salt.
convertAtomX
        :: Show a 
        => Platform
        -> DataDefs L.Name
        -> Exp (AnTEC a L.Name) L.Name
        -> ConvertM a (Exp a S.Name)

convertAtomX pp defs xx
 = case xx of
        XVar _ UIx{}    -> throw $ ErrorMalformed     "Found anonymous binder"
        XApp{}          -> throw $ ErrorNotNormalized "Found XApp in atom position"
        XLAM{}          -> throw $ ErrorNotNormalized "Found XLAM in atom position"
        XLam{}          -> throw $ ErrorNotNormalized "Found XLam in atom position"
        XLet{}          -> throw $ ErrorNotNormalized "Found XLet in atom position"
        XCase{}         -> throw $ ErrorNotNormalized "Found XCase in atom position"

        XVar a u        
         -> do  u'  <- convertU u
                return $ XVar (annotTail a) u'

        XCon a u
         -> case u of
                UName nCtor     -> convertCtorAppX pp a defs nCtor []
                UPrim nCtor _   -> convertCtorAppX pp a defs nCtor []
                _               -> throw $ ErrorInvalidBound u


        XCast _ _ x     -> convertAtomX pp defs x

        -- Pass region parameters, as well data data type parameters to primops.
        XType t
         -> do  t'      <- convertT t
                return  $ XType t'

        XWitness w      -> liftM XWitness (convertWitnessX w)


-------------------------------------------------------------------------------
-- | Convert a witness expression to Salt
convertWitnessX
        :: Show a
        => Witness L.Name
        -> ConvertM a (Witness S.Name)

convertWitnessX ww
 = let down = convertWitnessX
   in  case ww of
            WVar n      -> liftM  WVar  (convertU n)
            WCon wc     -> liftM  WCon  (convertWiConX wc)        
            WApp w1 w2  -> liftM2 WApp  (down w1) (down w2)
            WJoin w1 w2 -> liftM2 WApp  (down w1) (down w2)
            WType t     -> liftM  WType (convertT t)


convertWiConX
        :: Show a
        => WiCon L.Name
        -> ConvertM a (WiCon S.Name)    
convertWiConX wicon            
 = case wicon of
        WiConBuiltin w -> return $ WiConBuiltin w
        WiConBound n   -> liftM WiConBound (convertU n)


-------------------------------------------------------------------------------
convertCtorAppX 
        :: Show a
        => Platform 
        -> AnTEC a L.Name
        -> DataDefs L.Name
        -> L.Name
        -> [Exp (AnTEC a L.Name) L.Name]
        -> ConvertM a (Exp a S.Name)

convertCtorAppX pp a@(AnTEC t _ _ _) defs nCtor xsArgs

        -- Pass through unboxed literals.
        | L.NameBool b         <- nCtor
        , []                   <- xsArgs
        = do    t'              <- convertT t
                return $ XCon (annotTail a) (UPrim (S.NameBool b) t')

        | L.NameNat i          <- nCtor
        , []                   <- xsArgs
        = do    t'              <- convertT t
                return $ XCon (annotTail a) (UPrim (S.NameNat i) t')

        | L.NameInt i         <- nCtor
        , []                   <- xsArgs
        = do    t'              <- convertT t
                return $ XCon (annotTail a) (UPrim (S.NameInt i) t')

        | L.NameWord i bits    <- nCtor
        , []                   <- xsArgs
        = do    t'              <- convertT t
                return $ XCon (annotTail a) (UPrim (S.NameWord i bits) t')


        -- Construct algbraic data that has a finite number of data constructors.
        | Just ctorDef         <- Map.lookup nCtor $ dataDefsCtors defs
        , Just dataDef         <- Map.lookup (dataCtorTypeName ctorDef) $ dataDefsTypes defs
        = do    
                xsArgs'        <- mapM (convertAtomX pp defs) xsArgs

                -- Convert the types of each field.
                let makeFieldType x
                        = case takeAnnotOfExp x of
                                Nothing  -> return Nothing
                                Just a'  -> liftM Just $ convertT (annotType a')

                tsArgs'         <- mapM makeFieldType xsArgs
                constructData pp (annotTail a) dataDef ctorDef xsArgs' tsArgs'

-- If this fails then the provided constructor args list is probably malformed.
-- This shouldn't happen in type-checked code.
convertCtorAppX _ _ _ _nCtor _xsArgs
        = throw $ ErrorMalformed "convertCtorAppX: invalid constructor application"


-- Alt ------------------------------------------------------------------------
convertAlt 
        :: Show a
        => Platform                     -- ^ Platform specification.
        -> DataDefs L.Name              -- ^ Data type declarations.
        -> Env L.Name                   -- ^ Kind environment.
        -> Env L.Name                   -- ^ Type environment.
        -> a                            -- ^ Annotation from case expression.
        -> Bound L.Name                 -- ^ Bound of scrutinee.
        -> Alt (AnTEC a L.Name) L.Name  -- ^ Alternative to convert.
        -> ConvertM a (Alt a S.Name)

convertAlt pp defs kenv tenv a uScrut alt
 = case alt of
        AAlt PDefault x
         -> do  x'      <- convertBodyX pp defs kenv tenv x
                return  $ AAlt PDefault x'

        -- Match against literal unboxed values.
        AAlt (PData uCtor []) x
         | UPrim nCtor _        <- uCtor
         , case nCtor of
                L.NameInt{}     -> True
                L.NameWord{}    -> True
                L.NameBool{}    -> True
                _               -> False
         -> do  uCtor'  <- convertU uCtor
                xBody1  <- convertBodyX pp defs kenv tenv x
                return  $ AAlt (PData uCtor' []) xBody1

        -- Match against algebraic data with a finite number
        -- of data constructors.
        AAlt (PData uCtor bsFields) x
         | Just nCtor    <- case uCtor of
                                UName n   -> Just n
                                UPrim n _ -> Just n
                                _         -> Nothing
         , Just ctorDef   <- Map.lookup nCtor $ dataDefsCtors defs
         -> do  
                let tenv'       = Env.extends bsFields tenv 
                uScrut'         <- convertU uScrut

                -- Get the tag of this alternative.
                let iTag        = fromIntegral $ dataCtorTag ctorDef
                let uTag        = UPrim (S.NameTag iTag) S.tTag

                -- Get the address of the payload.
                bsFields'       <- mapM convertB bsFields

                -- Convert the right of the alternative.
                xBody1          <- convertBodyX pp defs kenv tenv' x

                -- Add let bindings to unpack the constructor.
                xBody2          <- destructData pp a uScrut' ctorDef bsFields' xBody1

                return  $ AAlt (PData uTag []) xBody2

        AAlt{}          
         -> throw ErrorInvalidAlt


-- Data Constructor -----------------------------------------------------------
convertCtor 
        :: Show a
        => Platform
        -> DataDefs L.Name
        -> a 
        -> Bound L.Name 
        -> ConvertM a (Exp a S.Name)

convertCtor pp defs a uu
 = case uu of
        -- Literal values.
        UPrim (L.NameBool v) _   
          -> return $ XCon a (UPrim (S.NameBool v) S.tBool)

        UPrim (L.NameNat i) _   
          -> return $ XCon a (UPrim (S.NameNat i) S.tNat)

        UPrim (L.NameInt i) _   
          -> return $ XCon a (UPrim (S.NameInt i) S.tInt)

        UPrim (L.NameWord i bits) _   
          -> return $ XCon a (UPrim (S.NameWord i bits) (S.tWord bits))

        -- A Zero-arity data constructor.
        UPrim nCtor _
         | Just ctorDef         <- Map.lookup nCtor $ dataDefsCtors defs
         , Just dataDef         <- Map.lookup (dataCtorTypeName ctorDef) $ dataDefsTypes defs
         -> constructData pp a dataDef ctorDef [] []

        _ -> throw $ ErrorMalformed "convertCtor: invalid constructor"

