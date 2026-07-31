platform :ios, '16.0'

target 'SIOSP' do
  use_frameworks! linkage: :static

  # The app is only a consumer/demo. PJSIP is an implementation detail of Kit.
  pod 'CallWaveKit', path: '.'
  pod 'MobileVLCKit', '3.3.16.3'

  target 'SIOSPTests' do
    inherit! :search_paths
  end
end
