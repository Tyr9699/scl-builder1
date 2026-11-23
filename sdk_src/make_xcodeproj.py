#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成一个独立的 SCLAlertView.xcodeproj（动态 framework target）。
在构建机 macOS 上运行；仅需 Python 标准库。生成的工程包含全部 Swift 源文件，
产物为动态 framework，支持 device + simulator 归档并合并为 XCFramework。
"""
import os, uuid

BASE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.join(BASE, 'SCLAlertView.xcodeproj')
PBX = os.path.join(PROJ, 'project.pbxproj')

def uid():
    return uuid.uuid4().hex.upper()[:24]

def swift_files():
    out = []
    root = os.path.join(BASE, 'SCLAlertView')
    for d, _, fs in os.walk(root):
        for f in fs:
            if f.endswith('.swift'):
                out.append(os.path.join(d, f))
    return sorted(out)

files = swift_files()
# 用稳定 ID（按文件名 hash）避免每次生成不同
def sid(p):
    import hashlib
    return hashlib.md5(('file:'+p).encode()).hexdigest().upper()[:24]

file_ref_ids = {p: sid('ref'+p) for p in files}
build_ids = {p: sid('build'+p) for p in files}

main_group = uid()
products_group = uid()
src_group = uid()
product_ref = uid()
target_id = uid()
proj_id = uid()
proj_conf_list = uid()
target_conf_list = uid()
debug_proj = uid(); release_proj = uid()
debug_tgt = uid(); release_tgt = uid()
sources_build = uid(); frameworks_build = uid()

def rel(p):
    return os.path.relpath(p, BASE)

def q(s):
    return '"' + s.replace('"', '\\"') + '"'

lines = []
A = lines.append
A('// !$*UTF8*$!')
A('{')
A('\tarchiveVersion = 1;')
A('\tclasses = {')
A('\t};')
A('\tobjectVersion = 56;')
A('\tobjects = {')

# PBXFileReference
for p in files:
    A(f'\t\t{file_ref_ids[p]} /* {os.path.basename(p)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(os.path.basename(p))}; sourceTree = "<group>"; }};')
A(f'\t\t{product_ref} /* SCLAlertView.framework */ = {{isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = SCLAlertView.framework; sourceTree = BUILT_PRODUCTS_DIR; }};')

# PBXGroup
A(f'\t\t{main_group} /* Project Group */ = {{')
A('\t\t\tisa = PBXGroup;')
A('\t\t\tchildren = (')
A(f'\t\t\t\t{src_group} /* SCLAlertView */,')
A(f'\t\t\t\t{products_group} /* Products */,')
A('\t\t\t);')
A('\t\t\tsourceTree = "<group>";')
A('\t\t};')
A(f'\t\t{src_group} /* SCLAlertView */ = {{')
A('\t\t\tisa = PBXGroup;')
A('\t\t\tchildren = (')
for p in files:
    A(f'\t\t\t\t{file_ref_ids[p]} /* {os.path.basename(p)} */,')
A('\t\t\t);')
A('\t\t\tpath = SCLAlertView;')
A('\t\t\tsourceTree = "<group>";')
A('\t\t};')
A(f'\t\t{products_group} /* Products */ = {{')
A('\t\t\tisa = PBXGroup;')
A('\t\t\tchildren = (')
A(f'\t\t\t\t{product_ref} /* SCLAlertView.framework */,')
A('\t\t\t);')
A('\t\t\tname = Products;')
A('\t\t\tsourceTree = "<group>";')
A('\t\t};')

# PBXNativeTarget
A(f'\t\t{target_id} /* SCLAlertView */ = {{')
A('\t\t\tisa = PBXNativeTarget;')
A(f'\t\t\tbuildConfigurationList = {target_conf_list} /* Build configuration list for PBXNativeTarget "SCLAlertView" */;')
A('\t\t\tbuildPhases = (')
A(f'\t\t\t\t{sources_build} /* Sources */,')
A(f'\t\t\t\t{frameworks_build} /* Frameworks */,')
A('\t\t\t);')
A('\t\t\tbuildRules = ();')
A('\t\t\tdependencies = ();')
A('\t\t\tname = SCLAlertView;')
A(f'\t\t\tproductName = SCLAlertView;')
A(f'\t\t\tproductReference = {product_ref} /* SCLAlertView.framework */;')
A('\t\t\tproductType = "com.apple.product-type.framework";')
A('\t\t};')

# PBXProject
A(f'\t\t{proj_id} /* Project object */ = {{')
A('\t\t\tisa = PBXProject;')
A('\t\t\tattributes = {')
A('\t\t\t\tBuildIndependentTargetsInParallel = 1;')
A('\t\t\t\tLastUpgradeCheck = 1500;')
A('\t\t\t};')
A(f'\t\t\tbuildConfigurationList = {proj_conf_list} /* Build configuration list for PBXProject "SCLAlertView" */;')
A('\t\t\tcompatibilityVersion = "Xcode 14.0";')
A('\t\t\tdevelopmentRegion = en;')
A('\t\t\thasScannedForEncodings = 0;')
A('\t\t\tknownRegions = (')
A('\t\t\t\ten,')
A('\t\t\t\tBase,')
A('\t\t\t);')
A(f'\t\t\tmainGroup = {main_group};')
A(f'\t\t\tproductRefGroup = {products_group} /* Products */;')
A('\t\t\tprojectDirPath = "";')
A('\t\t\tprojectRoot = "";')
A('\t\t\ttargets = (')
A(f'\t\t\t\t{target_id} /* SCLAlertView */,')
A('\t\t\t);')
A('\t\t};')

# PBXSourcesBuildPhase
A(f'\t\t{sources_build} /* Sources */ = {{')
A('\t\t\tisa = PBXSourcesBuildPhase;')
A('\t\t\tbuildActionMask = 2147483647;')
A('\t\t\tfiles = (')
for p in files:
    A(f'\t\t\t\t{build_ids[p]} /* {os.path.basename(p)} in Sources */,')
A('\t\t\t);')
A('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
A('\t\t};')
# PBXFrameworksBuildPhase
A(f'\t\t{frameworks_build} /* Frameworks */ = {{')
A('\t\t\tisa = PBXFrameworksBuildPhase;')
A('\t\t\tbuildActionMask = 2147483647;')
A('\t\t\tfiles = ();')
A('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
A('\t\t};')

# build file entries
for p in files:
    A(f'\t\t{build_ids[p]} /* {os.path.basename(p)} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_ids[p]} /* {os.path.basename(p)} */; }};')

# XCBuildConfiguration (project)
common = [
    'IPHONEOS_DEPLOYMENT_TARGET = 13.0;',
    'SDKROOT = iphoneos;',
    'SWIFT_VERSION = 5.0;',
    'CLANG_ENABLE_MODULES = YES;',
    'ALWAYS_SEARCH_USER_PATHS = NO;',
    'ENABLE_BITCODE = NO;',
]
A(f'\t\t{debug_proj} /* Debug */ = {{')
A('\t\t\tisa = XCBuildConfiguration;')
A('\t\t\tbuildSettings = {'); [A('\t\t\t\t'+x) for x in common]; A('\t\t\t};')
A('\t\t\tname = Debug;')
A('\t\t};')
A(f'\t\t{release_proj} /* Release */ = {{')
A('\t\t\tisa = XCBuildConfiguration;')
A('\t\t\tbuildSettings = {'); [A('\t\t\t\t'+x) for x in common]; A('\t\t\t};')
A('\t\t\tname = Release;')
A('\t\t};')

tgt_common = [
    'PRODUCT_NAME = "$(TARGET_NAME)";',
    'PRODUCT_BUNDLE_IDENTIFIER = com.sclalertview.sdk;',
    'DEFINE_MODULE = YES;',
    'SKIP_INSTALL = NO;',
    'BUILD_LIBRARY_FOR_DISTRIBUTION = YES;',
    'SUPPORTS_MACCATALYST = NO;',
    'TARGETED_DEVICE_FAMILY = "1,2";',
    'SWIFT_OPTIMIZATION_LEVEL = "-O";',
    'CODE_SIGN_IDENTITY = "";',
    'CODE_SIGNING_ALLOWED = NO;',
]
A(f'\t\t{debug_tgt} /* Debug */ = {{')
A('\t\t\tisa = XCBuildConfiguration;')
A('\t\t\tbuildSettings = {'); [A('\t\t\t\t'+x) for x in tgt_common]; A('\t\t\t};')
A('\t\t\tname = Debug;')
A('\t\t};')
A(f'\t\t{release_tgt} /* Release */ = {{')
A('\t\t\tisa = XCBuildConfiguration;')
A('\t\t\tbuildSettings = {'); [A('\t\t\t\t'+x) for x in tgt_common]; A('\t\t\t};')
A('\t\t\tname = Release;')
A('\t\t};')

# XCConfigurationList
A(f'\t\t{proj_conf_list} /* Build configuration list for PBXProject "SCLAlertView" */ = {{')
A('\t\t\tisa = XCConfigurationList;')
A(f'\t\t\tbuildConfigurations = ({debug_proj}, {release_proj},);')
A('\t\t\tdefaultConfigurationIsVisible = 0;')
A('\t\t\tdefaultConfigurationName = Release;')
A('\t\t};')
A(f'\t\t{target_conf_list} /* Build configuration list for PBXNativeTarget "SCLAlertView" */ = {{')
A('\t\t\tisa = XCConfigurationList;')
A(f'\t\t\tbuildConfigurations = ({debug_tgt}, {release_tgt},);')
A('\t\t\tdefaultConfigurationIsVisible = 0;')
A('\t\t\tdefaultConfigurationName = Release;')
A('\t\t};')

A('\t};')
A('\trootObject = ' + proj_id + ' /* Project object */;')
A('}')

os.makedirs(PROJ, exist_ok=True)
with open(PBX, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines) + '\n')

# scheme 让 xcodebuild -scheme SCLAlertView 可用
SCH = os.path.join(PROJ, 'xcshareddata', 'xcschemes')
os.makedirs(SCH, exist_ok=True)
with open(os.path.join(SCH, 'SCLAlertView.xcscheme'), 'w', encoding='utf-8') as f:
    f.write(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.3">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}" BuildableName="SCLAlertView.framework" BlueprintName="SCLAlertView" ReferencedContainer="container:SCLAlertView.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')

print('OK: 生成', PROJ)
print('源文件数:', len(files))
