#!/usr/bin/env python3
from pathlib import Path
from zipfile import ZipFile,ZIP_DEFLATED
import os
root=Path(__file__).resolve().parents[1];out=root/'downloads';out.mkdir(exist_ok=True)
exe=Path(os.environ.get('COMPANION_EXE',out/'Companion.exe'))
if exe.exists():
 with ZipFile(out/'Companion-Windows.zip','w',ZIP_DEFLATED) as z:
  z.write(exe,'Companion.exe');z.write(root/'README.md','README.md')
  for f in (root/'licenses').glob('*'):z.write(f,'licenses/'+f.name)
with ZipFile(out/'Companion-Website-Source.zip','w',ZIP_DEFLATED) as z:
 for folder in ['docs','src','supabase','host','tests']:
  for f in (root/folder).rglob('*'):
   if f.is_file():z.write(f,str(f.relative_to(root)))
 for name in ['package.json','package-lock.json','Dockerfile','compose.yaml','.dockerignore']:
  z.write(root/name,name)
 z.write(root/'host'/'README.md','START-HERE.md')
print('Packages created in',out)
