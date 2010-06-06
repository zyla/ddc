{-# OPTIONS -fwarn-unused-imports #-}

module Type.Scheme
	( generaliseType 
	, checkContext )
where
import Type.Check.Danger
import Type.Effect.MaskLocal
import Type.Error
import Type.State
import Type.Plug		
import Type.Strengthen
import Type.Context
import Type.Pretty
import Shared.VarPrim
import Type.Plate.Collect
import Util
import DDC.Type
import DDC.Var.NameSpace
import DDC.Var
import DDC.Util.FreeVars
import qualified Shared.VarUtil		as Var
import qualified DDC.Main.Arg		as Arg
import qualified Data.Map		as Map
import qualified Data.Set		as Set

debug	= True
trace s	= when debug $ traceM s

-- | Generalise a type
generaliseType
	:: Var 			-- binding variable of the type being generalised
	-> Type			-- the type to generalise
	-> Set ClassId		-- the classIds which must remain fixed (non general)
	-> SquidM Type

generaliseType varT tCore envCids
 = {-# SCC "generaliseType" #-} generaliseType' varT tCore envCids 

generaliseType' varT tCore envCids
 = do
	args			<- gets stateArgs
	trace	$ "*** Scheme.generaliseType " % varT % "\n"
		% "\n"
		% "    tCore\n"
		%> prettyTS tCore	% "\n\n"

		% "    envCids          = " % envCids		% "\n"
		% "\n"

	-- flatten out the scheme so its easier for staticRs.. to deal with
	let tFlat	= flattenT tCore
	trace	$ "    tFlat\n"
		%> prettyTS tFlat	% "\n\n"

	-- Work out which cids can't be generalised in this type.
	-- 	Can't generalise regions in non-functions.
	--	... some data object is in the same region every time you use it.
	--
	let staticRsData 	= [cid | TVar k (UClass cid) <- Set.toList $ staticRsDataT    tFlat ]
	let staticRsClosure 	= [cid | TVar k (UClass cid) <- Set.toList $ staticRsClosureT tFlat ]

	trace	$ "    staticRsData     = " % staticRsData	% "\n"
		% "    staticRsClosure  = " % staticRsClosure	% "\n"


	--	Can't generalise cids which are under mutable constructors.
	--	... if we generalise these classes then we could update an object at one 
	--		type and read it at another, violating soundness.
	--	
	let staticDanger	= if Set.member Arg.GenDangerousVars args
					then []
					else dangerousCidsT tCore

	trace	$ "    staticDanger     = " % staticDanger	% "\n"

	-- These are all the cids we can't generalise
	let staticCids		
		= Set.unions
			[ envCids
			, Set.fromList staticRsData 
			, Set.fromList staticRsClosure
			, Set.fromList staticDanger]

	-- Rewrite non-static cids to the var for their equivalence class.
	tPlug			<- plugClassIds staticCids tCore

	trace	$ "    staticCids       = " % staticCids	% "\n\n"
		% "    tPlug\n"
		%> prettyTS tPlug 	% "\n\n"

	-- Clean empty effect and closure classes that aren't ports.
	let tsParam	=  slurpParamClassVarsT_constrainForm
	 		$  toConstrainFormT tPlug
	classInst	<- getsRef stateClassInst
	let tClean	= cleanType (Set.fromList tsParam) tPlug

	trace	$ "    tClean\n" 
			%> ("= " % prettyTS tClean)		% "\n\n"


	let tReduce	= reduceContextT classInst tClean
	trace	$ "    tReduce\n"
			%> ("= " % prettyTS tReduce)		% "\n\n"

--	trace	$ "     classInts = " % classInst		% "\n\n"

	-- Mask effects and Const/Mutable/Local/Direct constraints on local regions.
	-- 	Do this before adding foralls so we don't end up with quantified regions that
	--	aren't present in the type scheme.
	--
	let rsVisible	= visibleRsT $ flattenT tReduce
	let tMskLocal	= maskLocalT rsVisible tReduce

	trace	$ "    rsVisible    = " % rsVisible		% "\n\n"
	trace	$ "    tMskLocal\n"
		%> prettyTS tMskLocal 	% "\n\n"

	-- If we're generalising the type of a top level binding, 
	--	and if any of its free regions are unconstraind,
	--	then make them constant.
	vsBoundTop	<- getsRef stateVsBoundTopLevel
	let isTopLevel	= Set.member varT vsBoundTop
	let fsMskLocal	= takeTFetters tMskLocal
	let rsMskLocal	= Set.toList $ collectTClasses tMskLocal
	
	trace	$ "    isTopLevel   = " % isTopLevel		% "\n\n"

	let fsMore
		| isTopLevel
		=  [ FConstraint primConst [tR]
			| tR@(TVar kR (UClass cid))	<- rsMskLocal
			, kR	== kRegion
			, notElem (FConstraint primMutable [tR]) fsMskLocal ]

		++ [ FConstraint primDirect [tR]
			| tR@(TVar kR (UClass cid)) <- rsMskLocal
			, kR	== kRegion
			, notElem (FConstraint primLazy [tR]) fsMskLocal ]
	
		| otherwise
		= []
		
	let tConstify	= addFetters fsMore tMskLocal

	trace	$ "    tConstify    = " % tConstify 		% "\n\n"

	-- Check context for problems
	checkContext tConstify

	-- Quantify free variables.
	let vsFree	= filter (\v -> not $ varNameSpace v == NameValue)
			$ filter (\v -> not $ Var.isCtorName v)
			$ Var.sortForallVars
			$ Set.toList $ freeVars tConstify

	let vksFree	= map 	 (\v -> (v, let Just k = kindOfSpace $ varNameSpace v in k)) 
			$ vsFree

	trace	$ "    vksFree   = " % vksFree	% "\n\n"
	let tScheme	= toFetterFormT
			$ quantifyVarsT_constrainForm vksFree 
			$ toConstrainFormT tConstify

	-- Remember which vars are quantified
	--	we can use this information later to clean out non-port effect and closure vars
	--	once the solver is done.
	let vtsMore	= Map.fromList 
			$ [(v, t)	| FMore (TVar k (UVar v)) t
					<- slurpFetters tScheme]
	
	
	-- lookup :> bounds for each quantified var
	let (vkbsFree	:: [(Var, (Kind, Maybe Type))])
		= map (\(v, k) -> (v, (k, Map.lookup v vtsMore))) vksFree

	stateQuantifiedVarsKM 	`modifyRef` Map.union (Map.fromList vkbsFree)
	stateQuantifiedVars	`modifyRef` Set.union (Set.fromList vsFree) 

	trace	$ "    tScheme\n"
		%> prettyTS tScheme 	% "\n\n"

	return	tScheme


slurpFetters tt
	= case tt of
		TForall b k t'	-> slurpFetters t'
		TFetters _ fs	-> fs
		_		-> []


-- | Empty effect and closure eq-classes which do not appear in the environment or 
--	a contra-variant position in the type can never be anything but _|_,
--	so we can safely erase them now.
--
--   TODO:
--	We need to run the cleaner twice to handle types like this:
--		a -(!e1)> b
--		:- !e1 = !{ !e2 .. !en }
--
--	where all of !e1 .. !en are cleanable.
--	Are two passes enough?
--	
cleanType :: Set Type -> Type -> Type
cleanType tsSave tt
 = let 	vsKeep	= Set.fromList
		$ catMaybes
 		$ map (\t -> case t of
				TVar k (UVar v)
				 	| k == kEffect || k == kClosure
					-> Just v
				
				_	-> Nothing)
		$ Set.toList tsSave
		
   in	finaliseT vsKeep False tt
 

-- | After reducing the context of a type to be generalised, if certain constraints
--	remain then this is symptomatic of problems in the source program.
-- 
--	Projection constraints indicate an ambiguous projection.
--	Shape constraints indicate 
--	Type class constraints indicate that no instance for this type is available.
--
checkContext :: Type -> SquidM ()
checkContext tt
 = case tt of
 	TFetters t fs	-> mapM_ checkContextF fs
	_		-> return ()
 
checkContextF ff
 = case ff of
 	FProj j vInst tDict tBind
	 -> addErrors
	 	[ ErrorAmbiguousProjection
			{ eProj		= j } ]

	FConstraint vClass ts
	 | not 	$ elem vClass
	 	[ primMutable,	primMutableT
		, primConst,	primConstT
		, primLazy, 	primDirect
		, primPure,	primEmpty
		, primLazyH ]
	 , varName vClass /= "Safe"
	 -> addErrors
	 	[ ErrorNoInstance
			{ eClassVar		= vClass
			, eTypeArgs		= ts 
			, eFetterMaybeSrc	= Nothing } ] -- TODO: find the source
		
	_ -> return ()
	
