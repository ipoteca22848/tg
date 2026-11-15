#!/usr/bin/env python3
"""Build an installable, debug-signed Android APK using the official Android SDK.
No Gradle or AndroidX dependencies. Requires JDK 21+, platform 35 and build-tools 35.0.0.
Set ANDROID_SDK_ROOT and COMPANION_KEYSTORE to directories outside the source tree.
"""
from pathlib import Path
import os,shutil,subprocess,zipfile
ROOT=Path(__file__).resolve().parents[1]
SDK=Path(os.environ['ANDROID_SDK_ROOT']);TOOLS=SDK/'build-tools'/'35.0.0';PLATFORM=SDK/'platforms'/'android-35'/'android.jar'
BUILD=Path(os.environ.get('COMPANION_BUILD_DIR',ROOT/'work'/'android-build'));BUILD.mkdir(parents=True,exist_ok=True)
KEY=Path(os.environ.get('COMPANION_KEYSTORE',BUILD.parent/'companion-debug.keystore'))
def run(*args):subprocess.run([str(x) for x in args],check=True,cwd=ROOT)
assets=BUILD/'assets'/'web';shutil.rmtree(assets.parent,ignore_errors=True);shutil.copytree(ROOT/'docs',assets)
run(TOOLS/'aapt2','compile','--dir',ROOT/'android'/'res','-o',BUILD/'resources.zip')
run(TOOLS/'aapt2','link','-o',BUILD/'unsigned.apk','--manifest',ROOT/'android'/'AndroidManifest.xml','-I',PLATFORM,'-A',assets.parent,'--auto-add-overlay',BUILD/'resources.zip')
classes=BUILD/'classes';shutil.rmtree(classes,ignore_errors=True);classes.mkdir()
sources=list((ROOT/'android'/'src').rglob('*.java'))
run('java','-m','jdk.compiler/com.sun.tools.javac.Main','-source','8','-target','8','-Xlint:-options','-classpath',PLATFORM,'-d',classes,*sources)
jar=BUILD/'classes.jar'
with zipfile.ZipFile(jar,'w') as z:
 for p in classes.rglob('*.class'):z.write(p,str(p.relative_to(classes)))
dex=BUILD/'dex';dex.mkdir(exist_ok=True)
run(TOOLS/'d8','--min-api','26','--lib',PLATFORM,'--output',dex,jar)
with zipfile.ZipFile(BUILD/'unsigned.apk','a',zipfile.ZIP_DEFLATED) as z:z.write(dex/'classes.dex','classes.dex')
run(TOOLS/'zipalign','-f','-p','4',BUILD/'unsigned.apk',BUILD/'aligned.apk')
if not KEY.exists():
 KEY.parent.mkdir(parents=True,exist_ok=True)
 run('keytool','-genkeypair','-keystore',KEY,'-storepass','android','-alias','androiddebugkey','-keypass','android','-keyalg','RSA','-keysize','2048','-validity','10000','-dname','CN=Companion Development,O=Companion,C=US')
output=ROOT/'downloads'/'Companion-Android.apk';output.parent.mkdir(exist_ok=True)
run(TOOLS/'apksigner','sign','--ks',KEY,'--ks-key-alias','androiddebugkey','--ks-pass','pass:android','--key-pass','pass:android','--out',output,BUILD/'aligned.apk')
run(TOOLS/'apksigner','verify','--verbose',output)
print('APK:',output)
