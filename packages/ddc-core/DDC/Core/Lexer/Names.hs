
module DDC.Core.Lexer.Names
        ( -- * Keywords
          keywords

          -- * Variable names
        , isVarName
        , isVarStart
        , isVarBody
        , readVar

          -- * Constructor names
        , isConName
        , isConStart
        , isConBody
        , readCon

          -- * Operator names
        , isOpName
        , isOpStart
        , isOpBody

          -- * Literal names
        , isLitName
        , isLitStart
        , isLitBody)
where
import DDC.Core.Lexer.Tokens
import DDC.Core.Lexer.Unicode
import DDC.Data.ListUtils
import Data.Char
import qualified Data.Set               as Set


---------------------------------------------------------------------------------------------------
-- | Textual keywords in the core language.
keywords :: [(String, Tok n)]
keywords
 =      [ ("module",     KA (KKeyword EModule))
        , ("import",     KA (KKeyword EImport))
        , ("export",     KA (KKeyword EExport))
        , ("foreign",    KA (KKeyword EForeign))
        , ("type",       KA (KKeyword EType))
        , ("value",      KA (KKeyword EValue))
        , ("capability", KA (KKeyword ECapability))
        , ("data",       KA (KKeyword EData))
        , ("in",         KA (KKeyword EIn))
        , ("of",         KA (KKeyword EOf))
        , ("letrec",     KA (KKeyword ELetRec))
        , ("letcase",    KA (KKeyword ELetCase))
        , ("private",    KA (KKeyword EPrivate))
        , ("extend",     KA (KKeyword EExtend))
        , ("using",      KA (KKeyword EUsing))
        , ("let",        KA (KKeyword ELet))
        , ("case",       KA (KKeyword ECase))
        , ("purify",     KA (KKeyword EPurify))
        , ("box",        KA (KKeyword EBox))
        , ("run",        KA (KKeyword ERun))
        , ("weakeff",    KA (KKeyword EWeakEff))
        , ("with",       KA (KKeyword EWith))
        , ("where",      KA (KKeyword EWhere) )
        , ("do",         KA (KKeyword EDo))
        , ("match",      KA (KKeyword EMatch))
        , ("if",         KA (KKeyword EIf))
        , ("then",       KA (KKeyword EThen))
        , ("else",       KA (KKeyword EElse))
        , ("otherwise",  KA (KKeyword EOtherwise)) ]


-- Variable names ---------------------------------------------------------------------------------
-- | String is a variable name
isVarName :: String -> Bool
isVarName str
 = case str of
     []          -> False
     c : cs 
        | isVarStart c 
        , and (map isVarBody cs)
        -> True
        
        | _ : _         <- cs
        , Just initCs   <- takeInit cs
        , isVarStart c
        , and (map isVarBody initCs)
        , last cs == '#'
        -> True

        | otherwise
        -> False


-- | Charater can start a variable name.
isVarStart :: Char -> Bool
isVarStart c
        =  isLower c
        || c == '?'
        || c == '_'
        

-- | Character can be part of a variable body.
isVarBody  :: Char -> Bool
isVarBody c
        =  isUpper c 
        || isLower c 
        || isDigit c 
        || c == '_' 
        || c == '\'' 
        || c == '$'


-- | Read a named, user defined variable.
readVar :: String -> Maybe String
readVar ss
        | isVarName ss  = Just ss
        | otherwise     = Nothing


-- Constructor names ------------------------------------------------------------------------------
-- | String is a constructor name.
isConName :: String -> Bool
isConName str
 = case str of
     []          -> False
     c : cs 
        | isConStart c 
        , and (map isConBody cs)
        -> True
        
        | _ : _         <- cs
        , Just initCs   <- takeInit cs
        , isConStart c
        , and (map isConBody initCs)
        , last cs == '#'
        -> True

        | otherwise
        -> False

-- | Character can start a constructor name.
isConStart :: Char -> Bool
isConStart = isUpper


-- | Charater can be part of a constructor body.
isConBody  :: Char -> Bool
isConBody c     
        =  isUpper c 
        || isLower c 
        || isDigit c 
        || c == '_'
        

-- | Read a named, user defined `TcCon`.
readCon :: String -> Maybe String
readCon ss
        | isConName ss  = Just ss
        | otherwise     = Nothing


-- Operator names ---------------------------------------------------------------------------------
-- | String is the name of some operator.
isOpName :: String -> Bool
isOpName str
 = case str of
        []      -> False
        c : cs
         | isOpStart c
         , and (map isOpBody cs)
         -> True

         | otherwise
         -> False


-- | Character can start an operator.
isOpStart :: Char -> Bool
isOpStart c
        =  c == '~'     || c == '!'                     || c == '#'     
        || c == '$'     || c == '%'                     || c == '&'     
        || c == '*'     || c == '-'     || c == '+'     || c == '='
        || c == ':'                     || c == '/'     || c == '|'
        || c == '<'     || c == '>'
        || Set.member c unicodeOperatorsInfix


-- | Character can be part of an operator body.
isOpBody :: Char -> Bool
isOpBody c
        =  c == '~'     || c == '!'                     || c == '#'     
        || c == '$'     || c == '%'     || c == '^'     || c == '&'     
        || c == '*'     || c == '-'     || c == '+'     || c == '='
        || c == ':'     || c == '?'     || c == '/'     || c == '|'
        || c == '<'     || c == '>'
        || Set.member c unicodeOperatorsInfix


-- Literal names ----------------------------------------------------------------------------------
-- | String is the name of a literal.
isLitName :: String -> Bool
isLitName str
 = case str of
        []      -> False
        c : cs
         | isLitStart c
         , and (map isLitBody cs)
         -> True

         | otherwise
         -> False

-- | Character can start a literal.
isLitStart :: Char -> Bool
isLitStart c
        =   isDigit c
        ||  c == '-'

-- | Character can be part of a literal body.
isLitBody :: Char -> Bool
isLitBody c
        =  isDigit c
        || c == 'b' || c == 'o' || c == 'x'
        || c == 'w' || c == 'f' || c == 'i' || c == 's'
        || c == '.'
        || c == '#'
        || c == '\''

