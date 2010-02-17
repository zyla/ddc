
-- | The renamer renames variables so all binding and bound occurances of a variable
--	in the same scope have the same variable ids. This lets us perform substitution
--	later in the compiler without having to worry about scope and variable capture.
--
--	This module defines the renamer monad and utils for renaming individual variables.
--
module Source.Rename.State
	( Rename (..)
	, RenameS(..)
	, RenameM, runRename
	, Scope(..)

	, initRenameS
	, traceM
	, addError

	, getCurrentScopeOfSpace
	, updateCurrentScopeOfSpace
	, withLocalScope
	, withModule

	, uniquifyVarN)

where

import Shared.Var		(Var, VarBind, NameSpace(..), (=~=), Module(..))
import Shared.VarPrim		(getPrimVarBind)
import Shared.Pretty
import Shared.Error
import Source.Error
import Util
import Util.Data.Map		(Map)
import qualified Shared.Var	as Var
import qualified Util.Data.Map	as Map

import Data.Set			(Set)
import qualified Data.Set	as Set
import qualified Debug.Trace
import Shared.VarUtil		(isCtorName)

-----
stage = "Source.Rename.State"
-- debug		= True
-- trace s xx	= if debug then Debug.Trace.trace (pprStrPlain s) xx else xx


-- Rename Class ------------------------------------------------------------------------------------
-- | things that can be renamed
class Rename a where
 rename  :: a -> RenameM a


-- | simple instances
instance Rename a => Rename [a] where
 rename xx	= mapM rename xx

instance Rename a => Rename (Maybe a) where
 rename xx 
  = case xx of
  	Nothing	-> return xx
	Just x	
	 -> do 	x'	<- rename x
		return $ Just x'

-- Variable Scopes ---------------------------------------------------------------------------------
data Scope
	= -- | In the top level scope of the program there can be many variables with the same name.
	  --   We use their module ids to distinguish them.
	  ScopeTop   (Map String [Var])

	  -- | A local scope within a single module.
	  --	In the scope stack each level contains all the vars bound by the same construct, 
	  --	eg, in (\x y z -> e), the vars {x, y, z} are all at the same level.
	  --	It's an error for multiple vars at the same binding level to have the same name.
	| ScopeLocal (Map String Var)
	deriving Show


-- Renamer State -----------------------------------------------------------------------------------

--	The variables for values and types exist in separate name spaces.
type	RenameM 	= State RenameS

data	RenameS 
	= RenameS
	{ -- | Accumulation of tracing / debugging info.
	  stateTrace		:: [String]

	  -- | Whether to generate tracing / debugging info.
	, stateDebug		:: Bool

	  -- | Renamer errors found so far.
	, stateErrors		:: [Error]


	, -- | The current module id
	  stateModule		:: Maybe Module

	  -- | Fresh variable generators, one for each namespace.
	, stateGen		:: Map NameSpace VarBind			

	  -- | The scopes for a particular namespace.
	  --   This starts out with just a ScopeTop element for each namespace.
	  --   The current scope is the head of the list.
	, stateScopes		:: Map NameSpace [Scope]

	  -- | A stack holding the currently opened object.
	  --	Objects are opened with ^ and their fields are referred to with _.
	  --	eg: printThing ^thing = print (_field1 % _field2)
	  --
	, stateObjectVar	:: [Var]
	}	


-- | Initial renamer state.
initRenameS
	= RenameS
	{ stateTrace		= []
	, stateDebug		= True
	, stateErrors		= []

	, stateModule		= Nothing

	, stateGen		= Map.fromList
				[ (NameModule,	Var.XBind "mR"  0)
				, (NameValue,	Var.XBind "vR"  0)
				, (NameType,	Var.XBind "tR"  0)
				, (NameRegion,	Var.XBind "rR"  0)
				, (NameEffect,	Var.XBind "eR"  0) 
				, (NameClosure, Var.XBind "cR"  0)
				, (NameField,	Var.XBind "fR"  0) 
				, (NameClass,	Var.XBind "aR"  0) ] 

	-- Each namespace starts out with an empty top level scope
	, stateScopes		= Map.fromList 
				$ zip allRenamedNameSpaces
				$ repeat [ScopeTop Map.empty]

	, stateObjectVar 	= []
	}

allRenamedNameSpaces
 = 	[ NameModule
	, NameValue
	, NameType, NameRegion, NameEffect, NameClosure
	, NameField
	, NameClass ]

-- | Add an error to the renamer state
addError :: Error -> RenameM ()
addError err
 	= modify $ \s -> s { stateErrors = stateErrors s ++ [err] }


-- | Add a message to the trace in the renamer state.
traceM	::  String -> RenameM ()
traceM ss
	= modify (\s -> s { stateTrace = (stateTrace s) ++ [ss] })
		
						
-- | run a renamer computation.
runRename :: RenameM a	-> a
runRename comp	
	= evalState comp initRenameS 

-- Scope management --------------------------------------------------------------------------------

-- | Lookup the current scope of a given NameSpace
getCurrentScopeOfSpace 
	:: NameSpace -> RenameM Scope

getCurrentScopeOfSpace space
 = do	Just (s:ss)	<- liftM (Map.lookup space)
			$  gets stateScopes
	return s

-- | Update the current scope of a given NameSpace with a new one
updateCurrentScopeOfSpace 
	:: NameSpace -> Scope -> RenameM ()

updateCurrentScopeOfSpace space scope'
 = do	Just (s:ss)	<- liftM (Map.lookup space)
			$  gets stateScopes
			
	modify 	$ \s -> s 
		{ stateScopes = Map.insert space (scope':ss) (stateScopes s) }


-- | Do some renaming in a local scope
withLocalScope :: RenameM a -> RenameM a
withLocalScope f
 = do	-- push local scope onto stack
	modify	$ \s -> s 
		{ stateScopes	= Map.map (\scopes -> ScopeLocal Map.empty : scopes) 
				$ stateScopes s }

	-- run the action
	x	<- f
	
	-- pop local scope from stack
	modify	$ \s -> s 
		{ stateScopes	= Map.map (\(s:scopes) -> scopes)
				$ stateScopes s }

	return x
	
-- | Do some renaming in a particular module
withModule :: Module -> RenameM a -> RenameM a
withModule mod f
 = do	mMod	<- gets stateModule
	case mMod of
	 Nothing
	  -> do	modify $ \s -> s { stateModule = Just mod }
		x <- f
		modify $ \s -> s { stateModule = Nothing }
		return x
		
	 Just mod'
	  -> 	panic stage $ "withModule: module is already set to " % mod'
	
	
-- Uniquifying Individual Vars -----------------------------------------------------------------------

-- | If this is the name of a primitive var then give it the appropriate VarId
--	otherwise give it a fresh, unique one. 
--	Also set the namespace
--	and the module id to the current module.
--
uniquifyVarN ::	NameSpace -> Var -> RenameM Var
uniquifyVarN space var

	-- If we're being told the the var has a different namespace to the one
	--	it's already in then something has gone wrong in the parser or renamer.
	| Var.nameSpace var /= NameNothing
	, Var.nameSpace var /= space
	= panic stage 
		$ "renameVarN: not renaming var " % var % " from space " % show (Var.nameSpace var)
		% " to space " % show space % "\n"
		% " var = " % show var % "\n"

	| otherwise
	= case getPrimVarBind space var of

		-- getPrimVarBind only gives us the unique binder
		--	Hopefully this binding occurrence is from tthe correct source module, 
		--	so we can set the moduleName based on that.
		--	REFACTOR: It'd be better if getPrimVarBind gave us all the right informaiton.
	 	Just bind	
		 -> do	Just mod	<- gets stateModule
			return 
		 	 $ var 	{ Var.bind		= bind
				, Var.nameSpace		= space
				, Var.nameModule	= mod }
									
		Nothing 	
		 -> uniquifyVarN' space var	

uniquifyVarN' space var
 = do	-- grab the fresh varid generator for this space
 	Just spaceGen	<- liftM (Map.lookup space)
			$  gets stateGen

	-- grab the id of the current module
	Just mod	<- gets stateModule

	-- rename the var and set its namespace
	let var'	= var 
			{ Var.bind 		= spaceGen 
			, Var.nameSpace		= space 
			, Var.nameModule	= mod }

	-- increment the varid generator
	let spaceGen'	= Var.incVarBind spaceGen
	modify $ \s -> s
		{ stateGen	= Map.insert space spaceGen' (stateGen s) }
	
	return var'



