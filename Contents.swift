//import UIKit
import Cocoa
import AVFoundation
import PlaygroundSupport
import Foundation
import Accelerate
import SceneKit

let audioFileURL = Bundle.main.url(forResource: "Amazing", withExtension: "mp3")!
var audioFile: AVAudioFile = try AVAudioFile(forReading: audioFileURL,commonFormat: AVAudioCommonFormat.pcmFormatFloat32,interleaved:false)
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
let format = audioFile.processingFormat
let mixer = engine.mainMixerNode
engine.connect(player, to: mixer, format: format)
let maxBufSize:Int = Int(audioFile.length)
let audioFrameCount = AVAudioFrameCount(audioFile.length)
let audioFileBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: audioFrameCount)
try audioFile.read(into: audioFileBuffer)
var filePointer = audioFileBuffer.floatChannelData?.pointee
let wSize:Int = 1024
let wHalfSize:Int = wSize/2
let bufferLog2:Int=Int(log2f(Float(wSize)))
var bufferIndex: Int = 0
let audioBufferCount:Int = 1
let pcmBufferCount = AVAudioFrameCount(wSize)
var audioBuffers: [AVAudioPCMBuffer] = [AVAudioPCMBuffer]()
for var i in 0..<audioBufferCount{
    audioBuffers.append(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:pcmBufferCount))
    audioBuffers.append(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:pcmBufferCount))
}
let audioQueue: DispatchQueue = DispatchQueue(label:"PlayerBufferQueue")
let audioSemaphore: DispatchSemaphore = DispatchSemaphore(value: audioBufferCount)

var fftNormFactor:Float = 2.0/Float(wSize)
let fftSetup:FFTSetup = vDSP_create_fftsetup(vDSP_Length(bufferLog2), FFTRadix(kFFTRadix2))!;
var magnitudes = [Float](repeating: 0.0, count: wHalfSize)
let bandNum = 32
let thita = Float(2*M_PI)/Float(bandNum)
let R:Float = Float(ceil(Double(bandNum)/2.0/M_PI))
var shouldLoad:Bool=false
var mAudioPlayer:AVAudioPlayer!
var loadedBufSize = 0
let samplePerBand = (wHalfSize/bandNum)
var freq = [Float](repeating:0.0,count:bandNum)
let filter = [Float](repeating:1/Float(samplePerBand*8),count:samplePerBand)
let factor:Double = 20.0
let period = (Int(format.sampleRate)*Int(factor)/wSize)
var count=period-16

func playMusic(){
    do{
        if mAudioPlayer==nil {
            mAudioPlayer = try AVAudioPlayer(contentsOf: audioFileURL)
            mAudioPlayer.play()
        }
    }catch let error as NSError{
        print(error.localizedDescription)
    }
}
func stopMusic(){
    if mAudioPlayer != nil {
        mAudioPlayer.stop()
        mAudioPlayer = nil
    }
}
var bandNode:SCNNode!
var scnview:SCNView!
func setup3DScene(){
    let scene = SCNScene()
    let groundGeometry = SCNFloor()
    groundGeometry.reflectivity = 0
    let groundMaterial = SCNMaterial()
    groundMaterial.diffuse.contents = NSColor.darkGray
    groundGeometry.materials = [groundMaterial]
    let ground = SCNNode(geometry:groundGeometry)
    scene.rootNode.addChildNode(ground)
    
    let cameraNode = SCNNode()
    cameraNode.camera = SCNCamera()
    cameraNode.camera?.zFar=1000
    cameraNode.camera?.zNear = 10
    cameraNode.position = SCNVector3Make(-30, 15, 30)
    let constrain = SCNLookAtConstraint(target:ground)
    constrain.isGimbalLockEnabled = true
    cameraNode.constraints = [constrain]
    scene.rootNode.addChildNode(cameraNode)
    
    let spotLight = SCNLight()
    spotLight.type = SCNLight.LightType.spot
    spotLight.castsShadow=true
    spotLight.spotInnerAngle=70.0
    spotLight.spotOuterAngle=90.0
    spotLight.zFar = 1000
    let light = SCNNode()
    light.light = spotLight
    light.position = SCNVector3(x:50,y:50,z:50)
    light.constraints = [constrain]
    scene.rootNode.addChildNode(light)
    
    
    bandNode = SCNNode()
    for i in 0..<bandNum {
        let node:SCNNode = {
            let n = SCNNode(geometry: SCNBox(width:1.0,height:1.0,length:1,chamferRadius:0))
            let deg = Float(i)*thita+Float(M_PI_2)
            let x = R*cos(deg)
            let z = R*sin(deg)
            n.position = SCNVector3(x,0,z)
            n.pivot = SCNMatrix4MakeRotation((CGFloat)(deg), 0, 1, 0)
            let h = CGFloat(Float(i)/Float(bandNum))
            let newColor = NSColor(hue:h,saturation:1,brightness:1.0,alpha:1.0)
            n.geometry?.materials.first?.diffuse.contents = newColor
            n.geometry?.materials.first?.emission.contents = newColor
            return n
        }()
        bandNode.addChildNode(node)
    }
    bandNode.runAction(SCNAction.repeatForever(SCNAction.rotateBy(x: 0, y: 2*CGFloat(M_PI), z: 0, duration: 30)))
    scene.rootNode.addChildNode(bandNode)
    
    scnview = SCNView(frame: CGRect(x: 0.0, y: 30.0, width: 500, height: 500.0))
    scnview.backgroundColor = NSColor.black
    scnview.allowsCameraControl = false
    scnview.autoenablesDefaultLighting = false
    scnview.showsStatistics = true
    scnview.scene = scene

}
setup3DScene()

func render3D(){
    SCNTransaction.begin()
    SCNTransaction.animationDuration=factor
    for i in 0..<bandNum where shouldLoad==true{
        let amp = freq[i]
        let node = bandNode.childNodes[i]
        node.position.y = CGFloat(amp)
        node.scale = SCNVector3(1,amp*2,1)
    }
    SCNTransaction.commit()
}
var hanWindow = [Float](repeating: 0.0, count: wSize)
vDSP_hann_window(&hanWindow, vDSP_Length(wSize), Int32(vDSP_HANN_NORM))
var hanWBuffer = [Float](repeating:0.0,count:wSize)
let tmp = UnsafePointer<Float>(hanWBuffer)
var imag = [Float](repeating: 0.0, count: wHalfSize)
var real = [Float](repeating: 0.0, count: wHalfSize)
var complexSplitBuffer = DSPSplitComplex(realp: &real, imagp: &imag)
func performFFT(){
    vDSP_vmul(filePointer!,1, hanWindow,1, &hanWBuffer,1, vDSP_Length(wSize))
    tmp.withMemoryRebound(to: DSPComplex.self, capacity: wHalfSize){ (dspComplexStream) -> Void in
        vDSP_ctoz(dspComplexStream,2,&complexSplitBuffer,1, vDSP_Length(wHalfSize))
        vDSP_fft_zrip(fftSetup, &(complexSplitBuffer), 1, UInt(bufferLog2), Int32(FFT_FORWARD))
        vDSP_zvabs(&complexSplitBuffer, 1, &magnitudes, 1, vDSP_Length(wHalfSize));
        var zero:Float = 16384.0
        vDSP_vdbcon(magnitudes, 1, &zero, &magnitudes,1, vDSP_Length(wHalfSize),1)
        var noiseFloor = Float(-128)
        var ceil:Float = 0.0
        vDSP_vclip(magnitudes,1,&noiseFloor,&ceil,&magnitudes,1,vDSP_Length(wHalfSize))
        vDSP_desamp(magnitudes,samplePerBand,filter,&freq,vDSP_Length(bandNum),vDSP_Length(samplePerBand))
        
        var Addi = Float(16)
        vDSP_vsadd(freq,1,&Addi,&freq,1,vDSP_Length(bandNum))
        //print(freq)
    }
}
func stop(){
    shouldLoad=false
    scnview.isPlaying = false
    stopMusic()
    //player.stop()
    //engine.stop()
    //print("stop!")
}

func loadnext(){
    while(shouldLoad){
        audioSemaphore.wait(timeout:.distantFuture)
        if loadedBufSize+wSize > maxBufSize {
            //receiver.stopBtnClicked()
            stop()
            break
        }
        
        let audiobuf = audioBuffers[bufferIndex]
        bufferIndex = (bufferIndex+1)%audioBufferCount
        let leftChannel = audiobuf.floatChannelData![0]
        let rightChannel = audiobuf.floatChannelData![1]
        leftChannel.assign(from: filePointer!, count: wSize)
        rightChannel.assign(from: filePointer!, count: wSize)
        audiobuf.frameLength = AVAudioFrameCount(wSize)
        
        count+=1
        if count > period {
            performFFT()
            count=0
            DispatchQueue.global().async{
                //DispatchQueue.main.async{
                //view.backgroundColor=UIColor.init(red: CGFloat(drand48()), green: CGFloat(drand48()), blue: CGFloat(drand48()), alpha: 1)
                render3D()
            }
        }
        filePointer = filePointer!.advanced(by: wSize)
        loadedBufSize+=wSize
        player.scheduleBuffer(audiobuf){
            audioSemaphore.signal()
        }
    }
}

func playAndRender(){
    DispatchQueue.global(qos:.userInteractive).async{
        loadnext()
    }
    do{
        try engine.start()
        player.play()
    }
    catch let error as NSError{
        print(error.localizedDescription)
    }
    scnview.isPlaying = true
}

func playWithRender(){
     scnview.isPlaying = true
     DispatchQueue.global().async {
        playMusic()
     }
     DispatchQueue.global().async {
        LoopRender3D()
     }
}
func LoopRender3D(){
    while(shouldLoad){
        if loadedBufSize+wSize > maxBufSize {
            stop()
            break
        }
        count+=1
        filePointer = filePointer!.advanced(by: wSize)
        loadedBufSize+=wSize
        if count > period {
            performFFT()
            render3D()
            count=0
        }
    }
}
class Receiver:NSObject {
    func playbtnClicked(){
        if !player.isPlaying {
            shouldLoad=true
            playWithRender()
            //playAndRender()
            //print("start!")
        }
    }
    func stopBtnClicked(){
        stop()
    }
    
}

let receiver = Receiver()
let bgView = NSView(frame: CGRect(x: 0.0, y: 0.0, width: 500, height: 550.0))
bgView.layer?.backgroundColor = CGColor(red: 255, green: 255, blue: 255, alpha: 1)

let playBtn = NSButton(frame: CGRect(x: 180, y: 0, width: 50, height: 30))
playBtn.title = "Play"//, for: .normal)
//playBtn..setTitleColor(#colorLiteral(red: 0.3411764801, green: 0.6235294342, blue: 0.1686274558, alpha: 1), for: .normal)
playBtn.target = receiver
playBtn.action = #selector(Receiver.playbtnClicked)
playBtn.bezelStyle = NSBezelStyle.roundRect
//playBtn.addTarget(receiver, action: #selector(Receiver.playbtnClicked), for: .touchUpInside)

let stopBtn = NSButton(frame: CGRect(x: 270, y: 0, width: 50, height: 30))
stopBtn.title = "Stop"
stopBtn.target = receiver
stopBtn.action = #selector(Receiver.stopBtnClicked)
stopBtn.bezelStyle = NSBezelStyle.roundRect
//stopBtn.setTitle("Stop", for: .normal)
//stopBtn.setTitleColor(#colorLiteral(red: 1, green: 0.1491314173, blue: 0, alpha: 1), for: .normal)
//stopBtn.addTarget(receiver, action: #selector(Receiver.stopBtnClicked), for: .touchUpInside)

let overviewLbl = NSTextField(frame: CGRect(x:0,y:530,width:500,height:20))
overviewLbl.stringValue = "This player contains a colorful equilizer based on audio freqency. Click <Play> to start!";
//overviewLbl.textColor = #colorLiteral(red: 0.1764705926, green: 0.4980392158, blue: 0.7568627596, alpha: 1)
bgView.addSubview(playBtn)
bgView.addSubview(stopBtn)
bgView.addSubview(scnview!)
bgView.addSubview(overviewLbl)
PlaygroundPage.current.liveView = bgView
PlaygroundPage.current.needsIndefiniteExecution = true
