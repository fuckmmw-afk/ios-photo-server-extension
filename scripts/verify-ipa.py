import plistlib
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = archive.namelist()
    app = 'Payload/PhotoServer.app/'
    ext = app + 'PlugIns/PhotoEditingExtension.appex/'
    assert all(n.startswith('Payload/') for n in names)
    assert not any(n.endswith('embedded.mobileprovision') or '/_CodeSignature/' in n for n in names)
    app_info = plistlib.loads(archive.read(app + 'Info.plist'))
    ext_info = plistlib.loads(archive.read(ext + 'Info.plist'))
    assert ext_info['CFBundleIdentifier'].startswith(app_info['CFBundleIdentifier'] + '.')
    assert ext_info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.photo-editing'
    principal = ext_info['NSExtension']['NSExtensionPrincipalClass']
    assert principal == 'PhotoEditingViewController' or principal.endswith('.PhotoEditingViewController')
    for path, info in [(app, app_info), (ext, ext_info)]:
        assert path + info['CFBundleExecutable'] in names
        assert info['MinimumOSVersion'] == '18.0'
    print('Verified IPA layout, identifiers, extension point and absence of signing resources.')
