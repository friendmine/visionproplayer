#!/usr/bin/env python3
"""Generate a dependency-free Xcode project; rerun after adding source/resource files."""
from pathlib import Path
import hashlib
import json
root = Path(__file__).resolve().parents[1]
project = root / 'VisionProPlayer.xcodeproj'
project.mkdir(exist_ok=True)
objects = {}
def uid(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(str(value))
def add(name, body):
    key = uid(name); objects[key] = body; return key
sources=[]; resources=[]; refs=[]
for path in sorted((root/'VisionProPlayer').rglob('*')):
    # Asset catalogs are compiled as a unit; their PNG/JSON children must not
    # also be copied into the app as loose resources.
    if any(parent.suffix == '.xcassets' for parent in path.parents): continue
    is_catalog = path.is_dir() and path.suffix == '.xcassets'
    if (not path.is_file() and not is_catalog) or path.name.startswith('.'): continue
    rel=path.relative_to(root).as_posix()
    ext=path.suffix
    types={'.xcassets':'folder.assetcatalog','.swift':'sourcecode.swift','.metal':'sourcecode.metal','.m':'sourcecode.c.objc','.h':'sourcecode.c.h','.usda':'text','.png':'image.png','.mp4':'file','.mkv':'file','.plist':'text.plist.xml'}
    ref=add(rel, f'isa = PBXFileReference; lastKnownFileType = {q(types.get(ext,"text"))}; path = {q(rel)}; sourceTree = SOURCE_ROOT;')
    refs.append(ref)
    if ext in ('.swift','.metal','.m','.usda','.png','.mp4','.mkv','.txt','.xcassets'):
        build=add('build:'+rel, f'isa = PBXBuildFile; fileRef = {ref};')
        (sources if ext in ('.swift','.m','.metal') else resources).append(build)
model_path = '.build/Models/DepthAnythingV2SmallF16.mlmodelc'
model_ref = add(model_path, f'isa = PBXFileReference; lastKnownFileType = folder; path = {q(model_path)}; sourceTree = SOURCE_ROOT;')
refs.append(model_ref)
resources.append(add('build:'+model_path, f'isa = PBXBuildFile; fileRef = {model_ref};'))
app=add('app','isa = PBXFileReference; explicitFileType = wrapper.application; path = VisionProPlayer.app; sourceTree = BUILT_PRODUCTS_DIR;')
pkg=add('package','isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/videolan/vlckit.git"; requirement = {kind = revision; revision = 2e0868f5ed40fe59cd92f377645fdcc260c6e759; };')
product=add('package-product',f'isa = XCSwiftPackageProductDependency; package = {pkg}; productName = VLCKit;')
framework=add('package-build',f'isa = PBXBuildFile; productRef = {product};')
def arr(items): return '('+','.join(items)+')'
src=add('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {arr(sources)}; runOnlyForDeploymentPostprocessing = 0;')
res=add('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {arr(resources)}; runOnlyForDeploymentPostprocessing = 0;')
fw=add('frameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({framework},); runOnlyForDeploymentPostprocessing = 0;')
products=add('products',f'isa = PBXGroup; children = ({app},); name = Products; sourceTree = "<group>";')
group=add('rootgroup',f'isa = PBXGroup; children = {arr(refs+[products])}; sourceTree = "<group>";')
configs=[]; pconfigs=[]
for mode in ['Debug','Release']:
    settings={
      'PRODUCT_BUNDLE_IDENTIFIER':'com.jeff.visionproplayer','PRODUCT_NAME':'$(TARGET_NAME)',
      'ARCHS':'arm64','SDKROOT':'xros','SUPPORTED_PLATFORMS':'xros xrsimulator','TARGETED_DEVICE_FAMILY':'7',
      'XROS_DEPLOYMENT_TARGET':'2.0','SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'targeted',
      'GENERATE_INFOPLIST_FILE':'YES','INFOPLIST_FILE':'VisionProPlayer/App/Info.plist',
      'INFOPLIST_KEY_CFBundleDisplayName':'Vision Player',
      'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon',
      'INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace':'YES',
      'INFOPLIST_KEY_UISupportsDocumentBrowser':'YES',
      'INFOPLIST_KEY_NSLocalNetworkUsageDescription':'播放你选择的局域网视频地址。',
      'MARKETING_VERSION':'0.2.0','CURRENT_PROJECT_VERSION':'2',
      'CODE_SIGN_STYLE':'Automatic','SWIFT_OBJC_BRIDGING_HEADER':'VisionProPlayer/Bridge/VisionProPlayer-Bridging-Header.h',
      'LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks',
      'SYSTEM_HEADER_SEARCH_PATHS':'$(inherited) $(BUILT_PRODUCTS_DIR)/VLCKit.framework/Headers','CLANG_ENABLE_MODULES':'YES','CLANG_ENABLE_OBJC_ARC':'YES',
      'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O',
      'DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym',
      'ENABLE_USER_SCRIPT_SANDBOXING':'YES',
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if mode=='Debug' else '',
      'GCC_PREPROCESSOR_DEFINITIONS':'DEBUG=1' if mode=='Debug' else 'NDEBUG=1',
    }
    configs.append(add('config:'+mode,'isa = XCBuildConfiguration; name = '+mode+'; buildSettings = {'+''.join(k+' = '+q(v)+';' for k,v in settings.items())+'};'))
    pconfigs.append(add('pconfig:'+mode,f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{CLANG_WARN_DOCUMENTATION_COMMENTS = YES; GCC_WARN_UNUSED_VARIABLE = YES; }};'))
cl=add('configlist',f'isa = XCConfigurationList; buildConfigurations = {arr(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
pcl=add('pconfiglist',f'isa = XCConfigurationList; buildConfigurations = {arr(pconfigs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target=add('target',f'isa = PBXNativeTarget; buildConfigurationList = {cl}; buildPhases = ({src},{fw},{res},); buildRules = (); dependencies = (); name = VisionProPlayer; productName = VisionProPlayer; productReference = {app}; productType = "com.apple.product-type.application"; packageProductDependencies = ({product},);')
proj=add('project',f'isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2700; }}; buildConfigurationList = {pcl}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base,); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},); packageReferences = ({pkg},);')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(k+' = {'+v+'};' for k,v in objects.items())+'\n}; rootObject = '+proj+';}\n')
schemes=project/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
reference=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="VisionProPlayer.app" BlueprintName="VisionProPlayer" ReferencedContainer="container:VisionProPlayer.xcodeproj"/>'
(schemes/'VisionProPlayer.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
