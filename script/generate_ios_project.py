"""Generate a native app + ReplayKit upload extension with local Swift package products."""
from pathlib import Path
import hashlib
import argparse
import re

parser = argparse.ArgumentParser()
parser.add_argument("--voice-only", action="store_true", help="Omit App Groups and ReplayKit signing capabilities")
parser.add_argument("--bundle-prefix", default="local.agentlive", help="Unique signing prefix; appends .ios and .ios.broadcast")
parser.add_argument("--team", default="", help="Apple Development Team ID")
arguments = parser.parse_args()
voice_only = arguments.voice_only
if not re.fullmatch(r'[A-Za-z0-9]+(?:[A-Za-z0-9.-]*[A-Za-z0-9])?',arguments.bundle_prefix) or not re.fullmatch(r'[A-Za-z0-9]*',arguments.team):
    parser.error("Use a bundle prefix containing letters, numbers, dots and hyphens, and an alphanumeric team ID")
prefix = arguments.bundle_prefix
project_name = "AgentLiveVoice" if voice_only else "AgentLive"
targets = ["app"] if voice_only else ["app", "broadcast"]

root = Path(__file__).resolve().parents[1] / 'iOS'
project = root / (project_name + '.xcodeproj')
project.mkdir(parents=True, exist_ok=True)
def ident(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
objects = []
def add(name, isa, fields):
    objects.append(f'\t\t{ident(name)} /* {name} */ = {{isa = {isa}; {fields} }};')
    return ident(name)
def values(names): return '(' + ', '.join(ident(name) for name in names) + ',)'

files = ['App/AgentLiveIOSApp.swift','App/MobileAudio.swift','App/Info.plist']
if not voice_only: files += ['Broadcast/SampleHandler.swift','App/AgentLive.entitlements','Broadcast/Info.plist','Broadcast/Broadcast.entitlements']

for path in files:
    kind = 'sourcecode.swift' if path.endswith('.swift') else 'text.plist.xml'
    add(path,'PBXFileReference',f'lastKnownFileType = {kind}; path = "{path}"; sourceTree = "<group>";')
add('app-product','PBXFileReference','explicitFileType = wrapper.application; includeInIndex = 0; path = "AgentLive.app"; sourceTree = BUILT_PRODUCTS_DIR;')
if not voice_only: add('broadcast-product','PBXFileReference','explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = "AgentLiveBroadcast.appex"; sourceTree = BUILT_PRODUCTS_DIR;')
add('products','PBXGroup',f'children = {values([target+"-product" for target in targets])}; name = Products; sourceTree = "<group>";')
add('main-group','PBXGroup',f'children = {values(files+["products"])}; sourceTree = "<group>";')
for file in [path for path in files if path.endswith('.swift')]: add('build-'+file,'PBXBuildFile',f'fileRef = {ident(file)};')
add('local-package','XCLocalSwiftPackageReference','relativePath = "..";')
for product, target in [('AgentServices','app'),('AgentUI','app'),('AgentServices','broadcast')]:
    if target not in targets: continue
    name = target+'-'+product
    add(name,'XCSwiftPackageProductDependency',f'package = {ident("local-package")}; productName = {product};')
    add('build-'+name,'PBXBuildFile',f'productRef = {ident(name)};')
add('app-sources','PBXSourcesBuildPhase',f'buildActionMask = 2147483647; files = {values(["build-"+p for p in files[:2]])}; runOnlyForDeploymentPostprocessing = 0;')
if not voice_only: add('broadcast-sources','PBXSourcesBuildPhase',f'buildActionMask = 2147483647; files = {values(["build-Broadcast/SampleHandler.swift"])}; runOnlyForDeploymentPostprocessing = 0;')
add('app-frameworks','PBXFrameworksBuildPhase',f'buildActionMask = 2147483647; files = {values(["build-app-AgentServices","build-app-AgentUI"])}; runOnlyForDeploymentPostprocessing = 0;')
if not voice_only: add('broadcast-frameworks','PBXFrameworksBuildPhase',f'buildActionMask = 2147483647; files = {values(["build-broadcast-AgentServices"])}; runOnlyForDeploymentPostprocessing = 0;')
if not voice_only: add('embed-broadcast','PBXBuildFile',f'fileRef = {ident("broadcast-product")}; settings = {{ ATTRIBUTES = (RemoveHeadersOnCopy,); }};')
if not voice_only: add('app-embed','PBXCopyFilesBuildPhase',f'buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = {values(["embed-broadcast"])}; name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;')
if not voice_only: add('broadcast-proxy','PBXContainerItemProxy',f'containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {ident("broadcast-target")}; remoteInfo = AgentLiveBroadcast;')
if not voice_only: add('broadcast-dependency','PBXTargetDependency',f'target = {ident("broadcast-target")}; targetProxy = {ident("broadcast-proxy")};')
for target, sourcefiles, products, bundle, name in [('app',files[:2],['app-AgentServices','app-AgentUI'],prefix+'.ios','AgentLive'),('broadcast',files[2:3],['broadcast-AgentServices'],prefix+'.ios.broadcast','AgentLiveBroadcast')]:
    if target not in targets: continue
    group = 'App' if target == 'app' else 'Broadcast'
    ent = 'AgentLive.entitlements' if target == 'app' else 'Broadcast.entitlements'
    for config in ['Debug','Release']:
        settings = f'CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = "{arguments.team}"; AGENT_LIVE_APP_GROUP = "group.{prefix}"; AGENT_LIVE_BROADCAST_BUNDLE = "{prefix}.ios.broadcast"; INFOPLIST_FILE = "{group}/Info.plist"; GENERATE_INFOPLIST_FILE = NO; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; TARGETED_DEVICE_FAMILY = "1,2"; PRODUCT_BUNDLE_IDENTIFIER = {bundle}; PRODUCT_NAME = {name}; SWIFT_VERSION = 5.0; SWIFT_OPTIMIZATION_LEVEL = "' + ('-Onone' if config == 'Debug' else '-O') + '";'
        if not voice_only: settings += f' AGENT_LIVE_KEYCHAIN_GROUP = "$(AppIdentifierPrefix){prefix}.shared"; CODE_SIGN_ENTITLEMENTS = "{group}/{ent}";'
        else: settings += ' SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) AGENT_LIVE_VOICE_ONLY";'
        settings += ' LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks";'
        if target == 'broadcast': settings += ' APPLICATION_EXTENSION_API_ONLY = YES; SKIP_INSTALL = YES;'
        add(target+'-'+config,'XCBuildConfiguration',f'buildSettings = {{ {settings} }}; name = {config};')
    add(target+'-configs','XCConfigurationList',f'buildConfigurations = {values([target+"-Debug",target+"-Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    phases = [target+'-sources',target+'-frameworks'] + (['app-embed'] if target == 'app' and not voice_only else [])
    dependencies = values(['broadcast-dependency']) if target == 'app' and not voice_only else '()'
    product_type = 'com.apple.product-type.application' if target == 'app' else 'com.apple.product-type.app-extension'
    add(target+'-target','PBXNativeTarget',f'buildConfigurationList = {ident(target+"-configs")}; buildPhases = {values(phases)}; buildRules = (); dependencies = {dependencies}; name = {name}; packageProductDependencies = {values(products)}; productName = {name}; productReference = {ident(target+"-product")}; productType = "{product_type}";')
for config in ['Debug','Release']:
    add('project-'+config,'XCBuildConfiguration',f'buildSettings = {{ CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos; }}; name = {config};')
add('project-configs','XCConfigurationList',f'buildConfigurations = {values(["project-Debug","project-Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target_attributes = ' '.join(ident(target+'-target')+' = { ProvisioningStyle = Automatic; };' for target in targets)
add('project','PBXProject',f'attributes = {{ LastUpgradeCheck = 1630; TargetAttributes = {{ {target_attributes} }}; }}; buildConfigurationList = {ident("project-configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ja; hasScannedForEncodings = 0; knownRegions = (ja, en, Base,); mainGroup = {ident("main-group")}; packageReferences = {values(["local-package"])}; productRefGroup = {ident("products")}; projectDirPath = ""; projectRoot = ""; targets = {values([target+"-target" for target in targets])};')
project.joinpath('project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(objects) + '\n}; rootObject = '+ident('project')+'; }\n')
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1630" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('app-target')}" BuildableName="AgentLive.app" BlueprintName="AgentLive" ReferencedContainer="container:{project_name}.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"/>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('app-target')}" BuildableName="AgentLive.app" BlueprintName="AgentLive" ReferencedContainer="container:{project_name}.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>'''
schemes = project/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True); (schemes/(project_name+'.xcscheme')).write_text(scheme)
print('Native iOS project generated:',project)
