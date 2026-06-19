Pod::Spec.new do |s|
  s.name           = 'AudioStreamer'
  s.version        = '1.0.0'
  s.summary        = 'Low-latency PCM audio streamer (WebSocket -> AVAudioEngine)'
  s.description    = 'Recibe PCM Int16 48kHz por WebSocket y lo reproduce con baja latencia y audio en segundo plano.'
  s.author         = ''
  s.homepage       = 'https://docs.expo.dev/modules/'
  s.platforms      = { :ios => '15.1', :tvos => '15.1' }
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }

  s.source_files = "**/*.{h,m,mm,swift,hpp,cpp}"
end
