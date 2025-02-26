{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE QuasiQuotes       #-}

module MacInstaller
  ( main
  , readCardanoVersionFile
  ) where

---
--- An overview of Mac .pkg internals:    http://www.peachpit.com/articles/article.aspx?p=605381&seqNum=2
---

import           Universum                 hiding (FilePath, toText, (<>))

import           Control.Exception         (handle)
import qualified Data.Text                 as T
import           Data.Aeson                (FromJSON(parseJSON), genericParseJSON, defaultOptions, decodeFileStrict')
import           Data.Yaml                 (decodeFileThrow)
import           Text.RawString.QQ
import           System.IO                 (BufferMode (NoBuffering),
                                            hSetBuffering)
import           System.IO.Error           (IOError, isDoesNotExistError)
import           System.Environment        (getEnv)
import           System.Posix.Files
import           Turtle                    hiding (e, prefix, stdout)


import           Config
import           RewriteLibs               (chain)
import           Types
import           Util                      (exportBuildVars, rewritePackageJson)

data DarwinConfig = DarwinConfig {
    dcAppNameApp :: Text -- ^ Daedalus.app for example
  , dcAppName :: Text -- ^ the Daedalus from Daedalus.app
  , dcPkgName :: Text -- ^ org.daedalus.pkg for example
  , dcDataDir :: Text -- ^ ${HOME}/Library/Application Support/Daedalus/qa
  } deriving (Show)

-- | The contract of `main` is not to produce unsigned installer binaries.
main :: Options -> IO ()
main opts@Options{oCodeSigningConfigPath,oSigningConfigPath,oCluster,oBackend,oBuildJob,oOutputDir,oTestInstaller} = do

  installerConfig <- decodeFileThrow "installer-config.json"

  hSetBuffering stdout NoBuffering

  mCodeSigningConfig <- case oCodeSigningConfigPath of
    Just path -> do
      decodeFileStrict' $ encodeString path
    Nothing -> do
      pure Nothing

  mSigningConfig <- case oSigningConfigPath of
    Just path -> do
      decodeFileStrict' $ encodeString path
    Nothing -> pure Nothing

  let
    darwinConfig = DarwinConfig {
        dcAppNameApp = (spacedName installerConfig) <> ".app"
      , dcAppName = spacedName installerConfig
      , dcPkgName = "org." <> (macPackageName installerConfig) <> ".pkg"
      , dcDataDir = dataDir installerConfig
      }
  print darwinConfig

  ver <- getBackendVersion oBackend
  exportBuildVars opts ver

  buildIcons oCluster
  appRoot <- buildElectronApp darwinConfig installerConfig
  makeComponentRoot opts appRoot darwinConfig installerConfig
  daedalusVer <- getDaedalusVersion "../package.json"

  let pkg = packageFileName Macos64 oCluster daedalusVer oBackend ver oBuildJob
      opkg = oOutputDir </> pkg

  print "appRoot:"
  print (tt appRoot)

  case mCodeSigningConfig of
    Just codeSigningConfig -> codeSignComponent codeSigningConfig appRoot
    Nothing -> pure ()

  tempInstaller <- makeInstaller opts darwinConfig appRoot pkg

  case mSigningConfig of
    Just signingConfig -> signInstaller signingConfig tempInstaller opkg
    Nothing -> cp tempInstaller opkg

  run "rm" [tt tempInstaller]
  printf ("Generated "%fp%"\n") opkg

  when (oTestInstaller == TestInstaller) $ do
    echo $ "--test-installer passed, will test the installer for installability"
    procs "sudo" ["installer", "-dumplog", "-verbose", "-target", "/", "-pkg", tt opkg] empty

  case mSigningConfig of
    Just _ -> do
      signed <- checkSignature opkg
      case signed of
        SignedOK -> pure ()
        NotSigned -> rm opkg
    Nothing -> pure ()

-- | Define the code signing script to be used for code signing
codeSignScriptContents :: String
codeSignScriptContents = [r|#!/run/current-system/sw/bin/bash
set -x
SIGN_ID="$1"
KEYCHAIN="$2"
REL_PATH="$3"
XML_PATH="$4"
ABS_PATH="$(pwd)/$REL_PATH"
TS="$(date +%Y-%m-%d_%H-%M-%S)"
function sign_cmd() {
  codesign --verbose=4 --deep --strict --timestamp --options=runtime --entitlements $XML_PATH --sign "$SIGN_ID" "$1" 2>&1 | tee -a /tmp/codesign-output-${TS}.txt
}
VERIFY_CMD="codesign --verbose=4 --verify --deep --strict"
ENTITLEMENT_CMD="codesign -d --entitlements :-"
LOG="2>&1 | tee -a /tmp/codesign-output-${TS}.txt"

# Remove symlinks pointing outside of the project build folder:
rm -f "$ABS_PATH/Contents/Resources/app/result"

# Ensure the code signing identity is found and set the keychain search path:
eval "security show-keychain-info \"$KEYCHAIN\" $LOG"
eval "security find-identity -v -p codesigning \"$KEYCHAIN\" $LOG"
eval "security list-keychains -d user -s \"$KEYCHAIN\" $LOG"

# Sign framework executables not signed by the deep sign command:
sign_cmd "$ABS_PATH/Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt"
sign_cmd "$ABS_PATH/Contents/Frameworks/Electron Framework.framework/Versions/Current/Resources/crashpad_handler"
sign_cmd "$ABS_PATH/Contents/Frameworks/Electron Framework.framework/Versions/Current/Libraries/libnode.dylib"
sign_cmd "$ABS_PATH/Contents/Frameworks/Electron Framework.framework/Versions/Current/Libraries/libffmpeg.dylib"

sign_cmd "$ABS_PATH/Contents/Frameworks/Electron Framework.framework/Versions/A/Libraries/libEGL.dylib"
sign_cmd "$ABS_PATH/Contents/Frameworks/Electron Framework.framework/Versions/A/Libraries/libGLESv2.dylib"
sign_cmd "$ABS_PATH/Contents/Frameworks/Electron Framework.framework/Versions/A/Libraries/libswiftshader_libEGL.dylib"
sign_cmd "$ABS_PATH/Contents/Frameworks/Electron Framework.framework/Versions/A/Libraries/libswiftshader_libGLESv2.dylib"
sign_cmd "$ABS_PATH/Contents/Frameworks/Electron Framework.framework/Versions/A/Libraries/libvk_swiftshader.dylib"

# Sign native electron bindings and supplementary binaries
sign_cmd "$ABS_PATH/Contents/Resources/app/build/usb_bindings.node"
sign_cmd "$ABS_PATH/Contents/Resources/app/build/HID.node"
sign_cmd "$ABS_PATH/Contents/Resources/app/node_modules/keccak/bin/darwin-x64-"*"/keccak.node"
sign_cmd "$ABS_PATH/Contents/Resources/app/node_modules/keccak/build/Release/addon.node"
sign_cmd "$ABS_PATH/Contents/Resources/app/node_modules/keccak/prebuilds/darwin-x64/node.napi.node"

# Sign the whole component deeply
sign_cmd "$ABS_PATH"

# Verify the signing
eval "$VERIFY_CMD \"$ABS_PATH\" $LOG"
eval "$VERIFY_CMD --display -r- \"$ABS_PATH\"" "$LOG"
eval "$ENTITLEMENT_CMD \"$ABS_PATH\"" "$LOG"
set +x|]

-- | Define the code signing entitlements to be used for code signing
codeSignEntitlements :: String
codeSignEntitlements = [r|<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key>
    <true/>
  </dict>
</plist>|]

makePostInstall :: Format a (Text -> a)
makePostInstall = "#!/usr/bin/env bash\n" %
                  "#\n" %
                  "# See /var/log/install.log to debug this\n" %
                  "\n" %
                  "src_pkg=\"$1\"\ndst_root=\"$2\"\ndst_mount=\"$3\"\nsys_root=\"$4\"\n" %
                  "./dockutil --add \"${dst_root}/" % s % "\" --allhomes\n"

makeScriptsDir :: Options -> DarwinConfig -> Managed T.Text
makeScriptsDir Options{oBackend} DarwinConfig{dcAppNameApp} = case oBackend of
    Cardano     _ -> common
  where
    common = do
      tmp <- fromString <$> (liftIO $ getEnv "TMP")
      tempdir <- mktempdir tmp "scripts"
      liftIO $ do
        cp "data/scripts/dockutil" (tempdir </> "dockutil")
        writeTextFile (tempdir </> "postinstall") (format makePostInstall dcAppNameApp)
        chmod executable (tempdir </> "postinstall")
      pure $ tt tempdir

makeSigningDir :: Managed (T.Text, T.Text)
makeSigningDir = do
    tmp <- fromString <$> (liftIO $ getEnv "TMP")
    tempdir <- mktempdir tmp "codeScripts"
    let
      codesignScriptPath = tempdir </> "codesignFnGen.sh"
      entitlementsPath = tempdir </> "entitlements.xml"
    liftIO $ do
      writeTextFile codesignScriptPath $ T.pack codeSignScriptContents
      chmod executable codesignScriptPath
      writeTextFile entitlementsPath $ T.pack codeSignEntitlements
    pure $ (tt codesignScriptPath, tt entitlementsPath)

buildIcons :: Cluster -> IO ()
buildIcons cluster = do
  let iconset = format ("icons/"%s%".iconset") (lshowText cluster)
  echo "Creating icons ..."
  procs "iconutil" ["--convert", "icns", "--output", "icons/electron.icns"
                   , iconset] mempty

-- | Builds the electron app with "yarn package" and returns its
-- component root path.
-- NB: If webpack scripts are changed then this function may need to
-- be updated.
buildElectronApp :: DarwinConfig -> InstallerConfig -> IO FilePath
buildElectronApp darwinConfig@DarwinConfig{dcAppName, dcAppNameApp} installerConfig = do
  withDir ".." . sh $ npmPackage darwinConfig

  let
    formatter :: Format r (Text -> Text -> r)
    formatter = "../release/darwin-x64/" % s % "-darwin-x64/" % s
    pathtoapp :: Text
    pathtoapp = format formatter dcAppName dcAppNameApp
    externalYarn :: [FilePath]
    externalYarn =
      [ "@babel"
      , "@trezor"
      , "base-x"
      , "base64-js"
      , "bchaddrjs"
      , "big-integer"
      , "bigi"
      , "bignumber.js"
      , "bip66"
      , "bitcoin-ops"
      , "blake2b"
      , "blake2b-wasm"
      , "bs58"
      , "bs58check"
      , "bytebuffer-old-fixed-webpack"
      , "call-bind"
      , "cashaddrjs"
      , "cbor-web"
      , "create-hash"
      , "create-hmac"
      , "cross-fetch"
      , "define-properties"
      , "ecurve"
      , "es-abstract"
      , "function-bind"
      , "get-intrinsic"
      , "has"
      , "has-symbols"
      , "hd-wallet"
      , "ieee754"
      , "inherits"
      , "int64-buffer"
      , "js-chain-libs-node"
      , "json-stable-stringify"
      , "keccak"
      , "long"
      , "merkle-lib"
      , "ms"
      , "nanoassert"
      , "node-fetch"
      , "object-keys"
      , "object.values"
      , "parse-uri"
      , "protobufjs-old-fixed-webpack"
      , "pushdata-bitcoin"
      , "queue"
      , "randombytes"
      , "regenerator-runtime"
      , "runtypes"
      , "safe-buffer"
      , "semver-compare"
      , "tiny-worker"
      , "trezor-connect"
      , "trezor-link"
      , "typeforce"
      , "varuint-bitcoin"
      , "wif"
      ]
  mapM_ (\lib -> do
      cptree ("../node_modules" </> lib) ((fromText pathtoapp) </> "Contents/Resources/app/node_modules" </> lib)
    ) externalYarn
  mktree ((fromText pathtoapp) </> "Contents/Resources/app/build")
  mapM_ (\(srcdir, name) -> cp ("../node_modules" </> srcdir </> name) ((fromText pathtoapp) </> "Contents/Resources/app/build" </> name)) [ ("usb/build/Release","usb_bindings.node"), ("node-hid/build/Release", "HID.node") ]
  rewritePackageJson (T.unpack $ pathtoapp <> "/Contents/Resources/app/package.json") (spacedName installerConfig)
  pure $ fromString $ T.unpack $ pathtoapp

npmPackage :: DarwinConfig -> Shell ()
npmPackage DarwinConfig{dcAppName} = do
  mktree "release"
  echo "Installing nodejs dependencies..."
  procs "yarn" ["install"] empty
  echo "Running electron packager script..."
  export "NODE_ENV" "production"
  procs "yarn" ["run", "package", "--", "--name", dcAppName ] empty
  size <- inproc "du" ["-sh", "release"] empty
  printf ("Size of Electron app is " % l % "\n") size
  procs "find" ["-name", "*.node"] empty

getBackendVersion :: Backend -> IO Text
getBackendVersion (Cardano     bridge) = readCardanoVersionFile bridge

makeComponentRoot :: Options -> FilePath -> DarwinConfig -> InstallerConfig -> IO ()
makeComponentRoot Options{oBackend,oCluster} appRoot darwinConfig@DarwinConfig{dcAppName} InstallerConfig{} = do
  let
      dir :: FilePath
      dir     = appRoot </> "Contents/MacOS"
      dataDir = appRoot </> "Contents/Resources"

  echo "Preparing files ..."
  let
    common :: FilePath -> IO ()
    common bridge = do
      -- Executables (from daedalus-bridge)
      forM_ ["cardano-launcher" ] $ \f ->
        cp (bridge </> "bin" </> f) (dir </> f)

      -- Config yaml
      cp "launcher-config.yaml" (dataDir </> "launcher-config.yaml")
  case oBackend of
    Cardano bridge -> do
      common bridge
      -- Executables (from daedalus-bridge)
      forM_ ["cardano-wallet", "cardano-node", "cardano-cli", "cardano-address" ] $ \f ->
        cp (bridge </> "bin" </> f) (dir </> f)
      forM_ ["config.yaml", "genesis.json", "genesis-byron.json", "genesis-shelley.json", "genesis-alonzo.json", "topology.yaml" ] $ \f ->
        cp f (dataDir </> f)

      when (oCluster == Selfnode) $ do
        cp "signing.key" (dataDir </> "signing.key")
        cp "delegation.cert" (dataDir </> "delegation.cert")

      procs "chmod" ["-R", "+w", tt dir] empty

      rmtree $ dataDir </> "app/installers"

      -- Rewrite libs paths and bundle them
      void $ chain (encodeString dir) $ fmap tt [dir </> "cardano-launcher", dir </> "cardano-wallet", dir </> "cardano-node", dir </> "cardano-cli", dir </> "cardano-address" ]
      let
        sortaMove :: FilePath -> IO ()
        sortaMove filename = do
          mv (appRoot </> "Contents/Resources/app/build" </> filename) (dir</>filename)
          symlink ("../../../MacOS" </> filename) (appRoot </> "Contents/Resources/app/build" </> filename)
      mapM_ sortaMove [ "usb_bindings.node" ]
      void $ chain (encodeString dir) [ tt $ dir </> "usb_bindings.node" ]
      let
        sortaMove :: FilePath -> IO ()
        sortaMove filename = do
          mv (appRoot </> "Contents/Resources/app/build" </> filename) (dir</>filename)
          symlink ("../../../MacOS" </> filename) (appRoot </> "Contents/Resources/app/build" </> filename)
      mapM_ sortaMove [ "HID.node" ]
      void $ chain (encodeString dir) [ tt $ dir </> "HID.node" ]

  -- Prepare launcher
  de <- testdir (dir </> "Frontend")
  unless de $ mv (dir </> (fromString $ T.unpack $ dcAppName)) (dir </> "Frontend")
  chmod executable (dir </> "Frontend")
  void $ writeLauncherFile dataDir darwinConfig
  maybeDarwinLauncher <- which "darwin-launcher"
  case maybeDarwinLauncher of
    Just darwinLauncher -> do
      let
        dest = dir </> (fromString $ T.unpack $ dcAppName)
      cp darwinLauncher dest
      chmod writable dest
      void $ chain (encodeString dir) [ tt dest ]
    Nothing -> do
      print "darwin-launcher was not found in $PATH"
      exit $ ExitFailure 1

makeInstaller :: Options -> DarwinConfig -> FilePath -> FilePath -> IO FilePath
makeInstaller opts@Options{oOutputDir} darwinConfig@DarwinConfig{dcPkgName} componentRoot pkg = do
  echo "Making installer ..."
  let tempPkg1 = format fp (oOutputDir </> pkg)
      tempPkg2 = oOutputDir </> (dropExtension pkg <.> "unsigned" <.> "pkg")

  mktree oOutputDir
  with (makeScriptsDir opts darwinConfig) $ \scriptsDir -> do
    let
      pkgargs :: [ T.Text ]
      pkgargs =
           [ "--identifier"
           , dcPkgName
           , "--scripts", scriptsDir
           , "--component"
           , tt componentRoot
           , "--install-location"
           , "/Applications"
           , tempPkg1
           ]
    run "ls" [ "-ltrh", scriptsDir ]
    run "pkgbuild" pkgargs

  run "productbuild" [ "--product", "data/plist"
                     , "--package", tempPkg1
                     , format fp tempPkg2
                     ]

  run "rm" [tempPkg1]
  pure tempPkg2

-- | cardano-sl.daedalus-bridge should have a file containing its version.
readCardanoVersionFile :: FilePath -> IO Text
readCardanoVersionFile bridge = prefix <$> handle handler (readTextFile verFile)
  where
    verFile = bridge </> "version"
    prefix = fromMaybe "UNKNOWN" . safeHead . T.lines
    handler :: IOError -> IO Text
    handler e | isDoesNotExistError e = pure ""
              | otherwise = throwM e

writeLauncherFile :: FilePath -> DarwinConfig -> IO FilePath
writeLauncherFile dir DarwinConfig{dcDataDir} = do
  writeTextFile path $ T.unlines contents
  chmod executable path
  setFileMode (encodeString path) anyReadExecute
  pure path
  where
    anyReadExecute = foldl unionFileModes nullFileMode [ ownerExecuteMode, ownerReadMode, groupExecuteMode, groupReadMode, otherExecuteMode, otherReadMode ]
    path = dir </> "helper"
    contents =
      [ "#!/usr/bin/env bash"
      , "mkdir -p \"" <> dcDataDir <> "/Secrets-1.0\""
      , "mkdir -p \"" <> dcDataDir <> "/Logs/pub\""
      ]

data CodeSigningConfig = CodeSigningConfig
  { codeSigningIdentity     :: T.Text
  , codeSigningKeyChain     :: T.Text
  } deriving (Show, Eq, Generic)

data SigningConfig = SigningConfig
  { signingIdentity         :: T.Text
  , signingKeyChain         :: Maybe T.Text
  , signingKeyChainPassword :: Maybe T.Text
  } deriving (Show, Eq, Generic)

instance FromJSON CodeSigningConfig where
  parseJSON = genericParseJSON defaultOptions

instance FromJSON SigningConfig where
  parseJSON = genericParseJSON defaultOptions

-- | Code sign a component.
codeSignComponent :: CodeSigningConfig -> FilePath -> IO ()
codeSignComponent CodeSigningConfig{codeSigningIdentity,codeSigningKeyChain} component = do
  with makeSigningDir $ \(codesignScriptPath, entitlementsPath) -> do
    run codesignScriptPath [ codeSigningIdentity
                           , codeSigningKeyChain
                           , (tt component)
                           , entitlementsPath ]

-- | Creates a new installer package with signature added.
signInstaller :: SigningConfig -> FilePath -> FilePath -> IO ()
signInstaller SigningConfig{signingKeyChain, signingIdentity} src dst =
  run "productsign" $ sign ++ keychain ++ map tt [src, dst]
  where
    sign = [ "--sign", signingIdentity ]
    keychain = maybe [] (\k -> [ "--keychain", k]) signingKeyChain

-- | This will raise an exception if signing was unsuccessful.
checkSignature :: FilePath -> IO SigningResult
checkSignature pkg = do
  result <- run' "pkgutil" ["--check-signature", tt pkg]
  pure $ case result of
           ExitSuccess -> SignedOK
           _           -> NotSigned

-- | Print the command then run it. Raises an exception on exit
-- failure.
run :: T.Text -> [T.Text] -> IO ()
run cmd args = do
    echoCmd cmd args
    procs cmd args mempty

-- | Print the command then run it.
run' :: T.Text -> [T.Text] -> IO ExitCode
run' cmd args = do
    echoCmd cmd args
    proc cmd args mempty

echoCmd :: T.Text -> [T.Text] -> IO ()
echoCmd cmd args = echo . unsafeTextToLine $ T.intercalate " " (cmd : args)
