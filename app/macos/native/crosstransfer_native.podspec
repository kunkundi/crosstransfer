Pod::Spec.new do |s|
  s.name             = 'crosstransfer_native'
  s.version          = '0.1.0'
  s.summary          = 'CrossTransfer native core (MiniRTC + crosstransfer_core).'
  s.description      = 'Prebuilt dynamic library produced by tools/build_native.sh; loaded from Dart via FFI.'
  s.homepage         = 'https://github.com/kunkundi/crosstransfer'
  s.license          = { :type => 'Proprietary', :text => 'Copyright (c) 2026 DI JUNKUN. All Rights Reserved.' }
  s.author           = { 'DI JUNKUN' => 'noreply@crosstransfer.app' }
  s.source           = { :path => '.' }
  s.platform         = :osx, '12.0'
  s.vendored_libraries = 'libcrosstransfer_native.dylib'
  s.frameworks       = 'Security', 'Foundation', 'SystemConfiguration', 'CoreFoundation'
  s.libraries        = 'z'
end
