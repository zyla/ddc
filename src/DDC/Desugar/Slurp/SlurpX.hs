{-# OPTIONS -fwarn-incomplete-patterns -fwarn-unused-matches -fwarn-name-shadowing #-}
-- | Constraint slurping for Expressions.
module DDC.Desugar.Slurp.SlurpX
	( slurpX )
where
import {-# SOURCE #-} DDC.Desugar.Slurp.SlurpS
import {-# SOURCE #-} DDC.Desugar.Slurp.SlurpA
import DDC.Desugar.Slurp.Base
import DDC.Solve.Location
import DDC.Var
import DDC.Base.DataFormat
import DDC.Main.Pretty
import Control.Monad
import Data.Bag			(Bag)
import Util			(unzip6, unzip5, takeLast, catMap)
import qualified Shared.VarUtil	as Var
import qualified Data.Set	as Set
import qualified Data.Bag	as Bag
import Data.Maybe

stage	= "DDC.Desugar.Slurp.SlurpX"

-- | Slurp out type constraints from an expression.
slurpX	:: Exp Annot1
	-> CSlurpM 
		( Type		-- type of expression.
		, Effect	-- effect of expression.
		, Closure	-- closure of expression.
		, Exp Annot2	-- annotated exp.
		, Bag CTree)	-- constraints.


-- Lam ------------------------------------------------------------------------
slurpX	xx@(XLambda sp vBound xBody)
 = do
	tX		<- newTVarDS "lam"
	cX		<- newTVarCS "lam"

	-- Create type vars for all the lambda bound vars.
	Just tBound@(TVar _ (UVar vBoundT))
			<- bindVtoT vBound
	
	-- Slurp the body.
	(tBody, eBody, _, xBody', qsBody)	
			<- slurpX xBody

	-- Get the closure terms for value vars free in this expression
	let freeVs	= Set.filter (\v ->  (varNameSpace v == NameValue)
					 &&  (not $ Var.isCtorName v))
			$ freeVars xx

	tsCloFree	<- mapM (\v -> do
					vT	<- lbindVtoT v
					return	$ makeTFreeBot v vT)
			$ Set.toList freeVs

	-- Get closure terms from unresolved projection functions
	let tsProjTags	= collectClosureProjTags xBody'
	let tsClo	= tsCloFree ++ tsProjTags

	-- the constraints
	let qs	= 
		[ CEq   (TSV $ SVLambda sp) tX	$ makeTFun tBound tBody eBody cX
		, CMore (TSC $ SCLambda sp) cX	$ makeTSum kClosure tsClo ]
 	
	-- If the sub expression is also a lambda then we can pack its constraints
	--	into this branch as well. This reduces the number of nested branches
	-- 	and saves indenting in the constraint file.
	let qs' = case xBody of
		XLambda{}
		  -> let [branch2]	= Bag.toList qsBody
		     in	 Bag.singleton $ CBranch
		     		{ branchBind 	= mergeCBinds (BLambda [vBoundT]) (branchBind branch2)
				, branchSub  	= qs ++ branchSub branch2 }
				
		_
		 -> Bag.singleton $ CBranch
		 		{ branchBind 	= BLambda [vBoundT]
				, branchSub  	= qs ++ Bag.toList qsBody }
	
	
	-- we'll be wanting to annotate these vars with TECs when we convert to core.
	wantTypeVs
		$  vBoundT
		:  [v | TVar kE (UVar v) <- [eBody],	kE == kEffect]
		++ [v | TVar kC (UVar v) <- [cX],	kC == kClosure]
	
	return	( tX
		, tPure
		, tEmpty
		, XLambdaTEC (Just (tX, tPure)) vBound xBody' tBound eBody cX
		, qs')


-- App ------------------------------------------------------------------------
slurpX	(XApp sp fun arg)
 = do
	tX		<- newTVarDS "app"
	eX		<- newTVarES "app"

	eApp@(TVar _ _)
			<- newTVarES "app"

	-- function
 	(tFun, eFun, _, fun', qsFun)	
			<- slurpX fun

	-- arg
	(tArg, eArg, _, arg', qsArg)	
			<- slurpX arg
	
	let qs	= constraints
		[ CEq   (TSV $ SVApp sp) tFun	$ makeTFun tArg tX eApp tEmpty 
		, CMore (TSE $ SEApp sp) eX	$ makeTSum kEffect  [eFun, eArg, eApp] ]
	
	return	( tX
		, eX
		, tEmpty
		, XApp (Just (tX, eX)) fun' arg'
		, qsFun >< qsArg >< qs)


-- Match ----------------------------------------------------------------------
slurpX	(XMatch sp (Just obj) alts)
 = do
	-- unification vars
	tRHS				<- newTVarDS "matRHS"
	eX				<- newTVarES "mat"
	eMatch@(TVar _ (UVar{}))	<- newTVarES "matI"

	-- object
	(tObj, eObj, _, obj', qsObj)	<- slurpX obj
	let TVar _ (UVar vObj) 		= tObj

	-- alternatives
	(tsAltsLHS, tsAltsRHS, esAlts, _, alts', qsAlts)	
			<- liftM unzip6 $ mapM slurpA alts

	let qsMatch	
		=  constraints
	  	$  makeCEqs (TSU $ SUAltLeft  sp) (tObj : tsAltsLHS)
		++ makeCEqs (TSU $ SUAltRight sp) (tRHS : tsAltsRHS)
		++ [ CMore  (TSE $ SEMatchObj sp) eMatch	$ TApp tHeadRead tObj
		   , CMore  (TSE $ SEMatch sp) eX $ makeTSum kEffect  ([eObj, eMatch] ++ esAlts) ]

	wantTypeV vObj

	return	( tRHS
		, eX
		, tEmpty
		, XMatch (Just (tRHS, eX)) (Just obj') alts'
		, qsMatch >< qsObj >< Bag.fromList qsAlts)


slurpX	(XMatch sp Nothing alts)
 = do
	-- unification vars
	tLHS		<- newTVarDS "matLHS"
	tRHS		<- newTVarDS "matRHS"
	eMatch		<- newTVarES "mat"

	-- alternatives
	(altsTP, altsTX, altsEs, _, alts', altsQs)	
			<- liftM unzip6 $ mapM slurpA alts
	
	let matchQs	
		=  constraints
		$  makeCEqs (TSU $ SUAltLeft sp)  (tLHS : altsTP)
		++ makeCEqs (TSU $ SUAltRight sp) (tRHS	: altsTX)
		++ [CMore   (TSE $ SEMatch sp) eMatch	$ makeTSum kEffect altsEs ]
				  
	return	( tRHS
		, eMatch
		, tEmpty
		, XMatch (Just (tRHS, eMatch)) Nothing alts'
		, matchQs >< Bag.fromList altsQs)


-- Lit ------------------------------------------------------------------------
slurpX	(XLit sp litFmt)
 = do	
 	tX@(TVar _ (UVar vT))	<- newTVarDS "lit"

	-- work out the type of this literal
	let TyConData 
		{ tyConName 	= tcVar
		, tyConDataKind = tcKind }
		= fromMaybe (panic stage $ "slurpX: no type for literal " % show litFmt)
		$ tyConOfLiteralFmt litFmt

	let tLitM
		-- unboxed numeric literals don't need region variables.
		| tcKind	== kValue
		= return $ makeTData tcVar tcKind []

		-- unboxed string literals are special because they
		-- actually have type (Ptr# (String# %r1))
		| tcVar		== primTString Unboxed
		= do	vR	<- newVarN NameRegion
			return	$ (tPtrU `TApp` makeTData tcVar tcKind [TVar kRegion $ UVar vR])

		-- boxed numeric literals need region vars
		| tcKind	== KFun kRegion kValue
		= do	vR	<- newVarN NameRegion
			return	$ makeTData tcVar tcKind [TVar kRegion $ UVar vR]
			
		| otherwise
		= panic stage $ "tLitM: no match"

	tLit	<- tLitM
	
	let qs 	= constraints
	 	[ CEq (TSV $ SVLiteral sp litFmt) tX tLit]

	wantTypeV vT
		
	return	( tX
		, tPure
		, tEmpty
	  	, XLit (Just (tX, tPure)) litFmt
		, qs)



-- Var ------------------------------------------------------------------------
slurpX 	xx@(XVar _ var)
 = do	tV@(TVar _ (UVar vT))	
		<- lbindVtoT    var
	
	wantTypeV vT
	slurpV xx tV


-- Do -------------------------------------------------------------------------
slurpX	(XDo sp stmts)
 = do
	tX		<- newTVarDS 	"do"
	eX		<- newTVarES	"do"
	
	--  Add all the bound vars to the bindMode map.
	let boundVs	= [v | Just v <- map bindingVarOfStmt stmts]
	
	-- Decend into each statement in turn.
	(tsStmts, esStmts, _, stmts', qssStmts)
			<- liftM unzip5 $ mapM slurpS stmts

	boundTVs	<- mapM getVtoT boundVs

	let Just tLast	= takeLast tsStmts
	let qsStmts	= Bag.concat qssStmts


	-- Signal that we're leaving the scope of all the let bindings in this block
	let letBindsC c	
		| CBranch{}	<- c
		, BLet vs	<- branchBind c
		= vs
		
		| otherwise
		= []

	let vsBind	= catMap letBindsC $ Bag.toList qsStmts
	let bindLeave	= case vsBind of
				[]	-> BNothing
				_	-> BLetGroup vsBind
			
	-- The type for this expression is the type of the last statement.
	let qs	= Bag.singleton 
		$ CBranch 
		{ branchBind	= bindLeave
		, branchSub	= 
			[ CEq   (TSV $ SVDoLast sp) tX 	$ tLast
			, CMore (TSE $ SEDo sp)	eX 	$ makeTSum  kEffect  esStmts ]
		   	++ Bag.toList qsStmts }

	wantTypeVs boundTVs

	return	( tX
		, eX
		, tEmpty
		, XDo (Just (tX, eX)) stmts'
		, qs)


-- If -------------------------------------------------------------------------
slurpX	(XIfThenElse sp xObj xThen xElse)
 = do	tAlts		<- newTVarDS 	"ifAlts"
	eX		<- newTVarES	"if"
	eTest		<- newTVarES 	"ifObj"

	-- Slurp the case object.
 	(tObj, eObj, _, xObj', qsObj)	<- slurpX xObj
	let TVar _ (UVar vObj) 		= tObj

	-- The case object must be a Bool
	tR		<- newTVarR
	let tBool'	= makeTData (primTBool Boxed) (KFun kRegion kValue) [tR]

	-- Slurp the THEN expression.
	(tThen, eThen, _, xThen', qsThen) <- slurpX xThen

	-- Slurp the ELSE expression.
	(tElse, eElse, _, xElse', qsElse) <- slurpX xElse
	
	let qs	= constraints
		$  [ CEq     (TSV $ SVIfObj sp)	tObj	$ tBool']
		++ (makeCEqs (TSU $ SUIfAlt sp)	(tAlts	: [tThen, tElse]))
		++ [ CMore   (TSE $ SEIfObj sp)	eTest 	$ TApp tHeadRead tObj
		   , CMore   (TSE $ SEIf sp) eX		$ makeTSum kEffect  [eObj, eThen, eElse, eTest] ]
		
	wantTypeV vObj
		
	return	( tAlts
		, eX
		, tEmpty
		, XIfThenElse (Just (tAlts, eX)) xObj' xThen' xElse'
		, qs >< qsObj >< qsThen >< qsElse )


-- Proj ------------------------------------------------------------------------
slurpX 	(XProj sp xBody proj)
 = do
	let (projT, label)	
		= case proj of
			JField  _ l	-> (TJField  l, l)
			JFieldR _ l	-> (TJFieldR l, l)

	-- the result of the projection
	tX	<- newTVarDS	"proj"
	eX	<- newTVarES	"proj"

	-- instance var for projection function.
	--	When we work out what the projection function is it'll be instantiated and bound to this var.
	(TVar _ (UVar vInst)) <- newTVarD

	-- effect and closure of projection function
	--	This will turn into the effect/closure of the function that is being applied
	--	to perform the projection - once we work out what that function is.
	--
	eProj	<- newTVarES	"proj"
	cProj	<- newTVarCS	"proj"

 	(tBody, eBody, _, xBody', qsBody)	<- slurpX xBody
	
	let proj'	= transformN (const Nothing) proj
			
	let qs	= constraints
		[ CProject (TSV $ SVProj sp projT)	
			projT vInst tBody (makeTFun tBody tX eProj cProj)

		, CMore	(TSE $ SEProj sp)	
			eX $ makeTSum kEffect  [eBody, eProj] ]

	return	( tX
		, eX
		, tEmpty
		, XProjTagged (Just (tX, eX)) vInst (makeTFreeBot label cProj) xBody' proj'
		, qsBody >< qs )


slurpX	(XProjT sp tDict proj)
 = do	
 	let (projT, label)	
		= case proj of
			JField  _ l	-> (TJField  l, l)
			JFieldR _ l	-> (TJFieldR l, l)

	-- the result of the projection
	tX	<- newTVarDS	"proj"
	eX	<- newTVarES	"proj"

	-- a var to tie the dictionary type to
	tDictVar <- newTVarDS	"proj"

	-- instance var for projection function.
	--	When we work out what the projection function is it'll be instantiated and bound to this var.
	(TVar _ (UVar vInst)) <- newTVarD

	-- closure of projection function
	-- 	Make a closure term out of the projection function, once we know what it is.
	--	This means that the caller knows that the projection function is free in it.
	--
	cProj	<- newTVarCS	"proj"

	let proj'	= transformN (const Nothing) proj

	let qs	= constraints
		[ CProject (TSV $ SVProj sp projT) projT vInst tDictVar tX 
		, CEq	   (TSV $ SVProj sp projT) tDictVar tDict
		, CEq      (TSV $ SVProj sp projT) cProj (makeTFreeBot label tX) ]

	return	( tX
		, eX
		, tEmpty
		, XProjTaggedT (Just (tX, eX)) vInst (makeTFreeBot label cProj) proj'
		, qs )

slurpX x
 = panic stage $ "slurpX: cannot slurp " ++ show x


-- | Make an Inst constraint for a variable.
slurpV (XVar sp var) (TVar k (UVar vT))
 = do
	vTu		<- makeUseVar var vT
	let tX		= TVar k $ UVar vTu
	let eX		= tPure
	let qs		= constraints
			[ CInst (TSV $ SVInst sp vT) vTu vT ]

	return	( tX
		, eX
		, tEmpty
	        , XVarInst (Just (tX, eX)) var
		, qs)

slurpV _ _	= panic stage $ "no match"

makeUseVar vInst vT
 = do 	TVar _ (UVar vTu_) <- newTVarD
	let vTu		= vTu_  
			{ varName = (varName vTu_)  ++ "_" ++ (varName vT) 
			, varInfo = [IValueVar vInst]}
 	
	return vTu



