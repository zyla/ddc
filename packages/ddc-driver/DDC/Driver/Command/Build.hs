
module DDC.Driver.Command.Build
        (cmdBuild)
where
import DDC.Driver.Config
import DDC.Driver.Build.Main
import DDC.Driver.Command.Compile
import DDC.Base.Pretty
import Control.Monad.Trans.Error
import Control.Monad.IO.Class
import qualified System.FilePath        as FilePath
import qualified DDC.Build.Spec.Parser  as Spec
import qualified DDC.Build.Builder      as Builder
import qualified Data.List              as List


-- Perform a build following a build specification.
cmdBuild :: Config -> FilePath -> ErrorT String IO ()
cmdBuild config filePath

 -- Build from a build spec file
 | ".build"      <- FilePath.takeExtension filePath
 = do
        -- Search for modules in the base library as well as the same directory
        -- the build file is in.
        let config'     
                = config
                { configModuleBaseDirectories
                        =  List.nub 
                        $  configModuleBaseDirectories config
                        ++ [ FilePath.takeDirectory filePath
                           , Builder.buildBaseSrcDir (configBuilder config) 
                                FilePath.</> "tetra" FilePath.</> "base" ]
                }

        -- Parse the spec file.
        str     <- liftIO $ readFile filePath
        case Spec.parseBuildSpec filePath str of
         Left err       -> throwError $ renderIndent $ ppr err
         Right spec     -> buildSpec config' spec


 -- If we were told to build a source file then just compile it instead.
 -- This is probably the least surprising behaviour.
 | ".ds"        <- FilePath.takeExtension filePath
 = do   cmdCompileRecursive config False [] filePath
        return ()

 -- Don't know how to build from this file.
 | otherwise
 = let  ext     = FilePath.takeExtension  filePath
   in   throwError $ "Cannot build from '" ++ ext ++ "' files."

