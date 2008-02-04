-----
-- Source.Defix
--
-- Summary:
--	Infix expression flattener.
--
--	Uses the fixity definitions at top level to rewrite all (Infix [expr]) nodes
--	as (App e1 e2) nodes in source tree.
--
--	Uses Haskell style resolution rules.
--		1) Expressions such as (e1 == e2 == e3), where == is defined as
--			non-associative, generate a resolution error.
--		
--		2) Cannot mix operators of same precedence, but differing associativities
--			in same infix expression.
--		
--		3) Unspecified Infix operators default to precedence 9, left associative.
--
-- Usage:
--	Use stripFixTable to strip the fixity table from a set of top level defs.
--	Then use defixT or defixE (passing it the fixity table) to defix the tree.
--	Resulting tree will have no (Infix [expr]) nodes.
--
-- Errors:
--	deathDefixNonAssoc
--	deathDefixMixedAssoc
--
--
module Source.Defix
	(defixP)

where

-----
import qualified Debug.Trace
import Control.Monad.State

import Util

-----
import qualified Shared.Var 	as Var
import Shared.Var (Var, (=~=))
import Shared.Error
import Shared.Base

import Source.Pretty
import Source.Exp
import Source.Error
import Source.Plate.Trans
import Source.DefixApps

-----
stage	= "Normal.Defix"

trace ss x	
	= Debug.Trace.trace (pprStr ss) x

-- | Resolve infix ops in this top level thing
--	Walk down the tree until we see an XDefix node and call defixInfix on the parts.
defixP ::	[FixDef] -> 	Top 	-> (Top, [Error])
defixP		fixTable	top	
 	= runState
	 	(transformXM (defixX fixTable) top)
		[]

defixX fixTable	x
 = case x of
 	XDefix sp xs	
	 -> do
		let result = defixInfix sp fixTable $ defixApps sp xs
		
		-- if we get error during the defix then add them to the state.
		case result of
		 Left  errs	
		  -> do	modify (\s -> s ++ errs)
			return x
		  		 
		 Right x'
		  -> 	return x'
		 		
	_ ->	return x


-----
defixInfix ::	SourcePos -> [FixDef] -> [Exp]	-> Either [Error] Exp
defixInfix	sp fixTable    es

	-- If there is only one element then we're already done
	| [e]			<- es
	= Right e

	-- If the first operator is a symbol then we've got a prefix application
	| XOp sp v : esRest	<- es
	, Right x'		<- defixInfix sp fixTable esRest
	= Right (XApp sp (XVar sp v) x')

	-- Otherwise keep calling defixEs until we've resolved all the operators
	| otherwise
	= case defixEs sp fixTable es of
		Left  errs	-> Left  errs
		Right es'	-> defixInfix sp fixTable es' 
	
-----
--- defixEs
---	Find the highest binding op, work out its precendence and 
---	call defixEsLeft / defixEsRight to turn it into an (App e1 e2) node
---
defixEs ::	SourcePos -> [FixDef] -> [Exp]	-> Either [Error] [Exp]
defixEs sp fixTable es 
 = let
	-- Get the list of ops in the expression.
	opVars		= map (\(XOp sp v) -> v)
			$ interslurp es

	-- Find the highest precedence of all ops in the expression.
	highPrec	= maximum 
			$ map (getPrec fixTable) 
			$ opVars

	-- Build a list of all ops having the highest precedence.
	opVarsHigh	= filter (\v -> getPrec fixTable v == highPrec) 
			$ opVars

	-- Build a list of associativities for these ops.
	assocs		= map (getAssoc fixTable) 
			$ opVarsHigh

 in case nub assocs of
 
 	[InfixLeft]	
	 -> Right $ defixEsLeft sp fixTable highPrec es

	[InfixRight]	
	 -> Right $ reverse 
		  $ defixEsRight sp fixTable highPrec 
		  $ reverse es

	[InfixNone]
	 -> defixEsNone sp fixTable highPrec es
	 
	_ -> 	Left [ErrorDefixMixedAssoc opVarsHigh]


-- | find uses of this operator and convert them to real function calls
defixEsNone :: SourcePos -> [FixDef] -> Int -> [Exp] -> Either [Error] [Exp]
defixEsNone sp fixTable highPrec xx

	-- If there are two ops in a row that are non-associative and have the same
	--	precedence then we don't know which one should be evaluated first
	--	
	| x1 : XOp spo2 op2 : x3 : XOp spo4 op4 : x5 : xs	<- xx
	, getPrec fixTable op2 == getPrec fixTable op4
	= Left [ErrorDefixNonAssoc [op2, op4]]

	-- found a use of the operator of interest
	| x1 : XOp spo2 op2 : x3 : xs				<- xx
	, getPrec fixTable op2 == highPrec
	= Right (XApp spo2 (XApp spo2 (XVar spo2 op2) x1) x3 : xs)

	-- some other operator
	| x1 : x2@XOp{} : x3 : xs				<- xx
	= case defixEsNone sp fixTable highPrec (x3 : xs) of
		Right xsRight	-> Right (x1 : x2 : xsRight)
		Left errs	-> Left errs

	| otherwise
	= panic stage 
		$ "defixEsNone: broken input expression."
		% xx
	
		 
-----
--- defixEsLeft
---	Find the left-most op with highPrec and turn it into an (App e1 e2) node.
---
defixEsLeft  :: SourcePos -> [FixDef] -> Int -> [Exp] -> [Exp]
defixEsLeft sp
	fixTable
	highPrec
	(e1 : (XOp spo op) : e2 : xs)

	| getPrec fixTable op 	== highPrec		
	= (XApp spo (XApp spo (XVar spo op) e1) e2) : xs
 
	| otherwise					
	= e1 : (XOp sp op) : defixEsLeft sp fixTable highPrec (e2 : xs)

defixEsLeft sp fixTable	highPrec	p	
	= panic stage "defixEsLeft: broken input expression."


-----
--- defixEsRight 
---	Find the right-most op with highPrec and turn it into an (App e1 e2) node.
---	Input expression list is reversed, so we can just can ('left' -> 'right')
---	Be careful to build the App node the right way around.
---
defixEsRight :: SourcePos -> [FixDef] -> Int -> [Exp] -> [Exp] 
defixEsRight sp	
	fixTable
	highPrec
	(e2 : (XOp spo op) : e1 : xs)

 	| getPrec fixTable op == highPrec
	= (XApp spo (XApp spo (XVar spo op) e1) e2) : xs
 
	| otherwise
	= e2 : (XVar sp op) : defixEsRight sp fixTable highPrec (e1 : xs)



-----
--- defaultFix
---	Unspecified infix operators default to the highest precedence = 10, assoc = Left.
---
defaultFix :: (Int, InfixMode)
defaultFix
	= (10, InfixLeft)


-----
--- getPrec / getAssoc
---	Get the prec / assoc for this var from the table.
---
getPrec  :: [FixDef] -> Var -> Int
getPrec  fixTable v
	= fst $ fromMaybe defaultFix $ lookupF (=~=) v fixTable

getAssoc :: [FixDef] -> Var -> InfixMode
getAssoc fixTable v	
	| otherwise
	= snd $ fromMaybe defaultFix $ lookupF (=~=) v fixTable


