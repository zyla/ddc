
module DDCI.Core.Command.Kind
        (cmdShowKind)
where
import DDCI.Core.Token
import DDC.Type.Pretty
import DDC.Type.Check.Exp
import qualified DDC.Type.Parser.Lexer  as TP
import qualified DDC.Type.Parser.Tokens as TP
import qualified DDC.Type.Parser        as TP
import DDC.Type.Exp
import Control.Monad


cmdShowKind :: String -> IO ()
cmdShowKind ss
 = case sequence (TP.lexType ss) of
        Nothing         -> putStrLn "lexical error"
        Just toks       -> showKind_toks $ map Token toks


showKind_toks :: [Token] -> IO ()
showKind_toks toks                
 = case parseType toks of 
        Left err        -> putStrLn $ "parse error " ++ show err
        Right t         -> showKind_type t

        
showKind_type :: Kind Token -> IO ()
showKind_type t
 = case kindOfType t of
        Left err        -> putStrLn $ show $ ppr err
        Right k         -> putStrLn $ show $ (ppr t <> text " :: " <> ppr k)
 

parseType :: [Token] -> Either TP.ParseError (Type Token)
parseType toks
 = let  tokenTable      = TP.liftTokens stringOfToken tokenOfString TP.tokenStrings
        fileName        = "foo"
   in   TP.runWrapParserG tokenTable
                stringOfToken posOfToken tokenOfString 
                fileName TP.pType toks
