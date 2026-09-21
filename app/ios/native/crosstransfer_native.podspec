Pod::Spec.new do |s|
  s.name = 'crosstransfer_native'
  s.version = '0.1.0'
  s.summary = 'CrossTransfer static transfer engine'
  s.homepage = 'https://github.com/kunkundi/crosstransfer'
  s.license = { :type => 'Proprietary', :file => '../../../LICENSE' }
  s.author = { 'DI JUNKUN' => 'junkun.di@hotmail.com' }
  s.source = { :path => '.' }
  s.platform = :ios, '15.0'
  s.vendored_frameworks = 'crosstransfer_native.xcframework'
  s.frameworks = 'Security', 'Foundation', 'SystemConfiguration', 'CoreFoundation'
  s.libraries = 'c++'
  # Dart resolves these from DynamicLibrary.process; there are no native callers.
  symbols = File.read(File.expand_path('../../../core/include/crosstransfer/ct_api.h', __dir__)).scan(/\b(Ct\w+)\s*\(/).flatten.uniq
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -Wl,-export_dynamic ' + symbols.map { |name| "-Wl,-u,_#{name}" }.join(' ')
  }
end
