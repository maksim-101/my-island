import Testing
import CoreGraphics
@testable import MyIslandCore

// Ported per D-02 from .planning/sketches/005-band-droplet/index.html:134-143 (Spring class) and
// 006-design-round/index.html:208-212 (MOT/POUR/DRAIN/DWELL/INTENT tables), both gitignored
// planning artifacts read directly from disk. The integrator reference values below were computed
// by an independent Python re-implementation of the exact same JS formula (semi-implicit Euler,
// k = (2π/resp)², c = 4π·damp/resp), not by re-deriving from this Swift port.

@Test func springPortMatchesSketchIntegrator() {
    let spring = FluidSpring(0)
    spring.to(1, preset: FluidMotionPreset(response: 0.55, damping: 0.78))
    let dt: CGFloat = 1.0 / 240.0

    spring.step(dt)
    #expect(abs(spring.x - 0.0022657494033722116) < 1e-9)
    #expect(abs(spring.v - 0.5437798568093308) < 1e-9)

    spring.step(dt)
    #expect(abs(spring.x - 0.006623869495491163) < 1e-9)
    #expect(abs(spring.v - 1.0459488221085484) < 1e-9)

    spring.step(dt)
    #expect(abs(spring.x - 0.01290911515381905) < 1e-9)
    #expect(abs(spring.v - 1.508458957998693) < 1e-9)
}

@Test func everyPresetSettles() {
    let presets: [FluidMotionPreset] = [.open, .close, .droplet, .slide, .sticky]
    let dt: CGFloat = 1.0 / 240.0
    let steps = Int(3.0 / Double(dt))
    for preset in presets {
        let spring = FluidSpring(0)
        spring.to(1, preset: preset)
        for _ in 0..<steps {
            spring.step(dt)
        }
        #expect(abs(spring.x - 1) < 0.001, "preset \(preset)")
        #expect(abs(spring.v) < 0.01, "preset \(preset)")
    }
}

@Test func underdampedPresetsOvershootOnce() {
    let dt: CGFloat = 1.0 / 240.0
    let steps = Int(3.0 / Double(dt))

    let open = FluidSpring(0)
    open.to(1, preset: .open)
    var openPeak: CGFloat = 0
    for _ in 0..<steps {
        open.step(dt)
        openPeak = max(openPeak, open.x)
    }
    #expect(openPeak > 1)
    #expect(openPeak < 1.1)

    let close = FluidSpring(0)
    close.to(1, preset: .close)
    var closePeak: CGFloat = 0
    for _ in 0..<steps {
        close.step(dt)
        closePeak = max(closePeak, close.x)
    }
    #expect(closePeak < 1.02)
}

@Test func jumpResetsVelocity() {
    let spring = FluidSpring(0)
    spring.to(1, preset: .open)
    spring.step(1.0 / 240.0)
    spring.jump(0.4)
    #expect(spring.x == 0.4)
    #expect(spring.t == 0.4)
    #expect(spring.v == 0)
}

@Test func scaleStretchesResponse() {
    let spring = FluidSpring(0)
    spring.to(1, preset: .open, scale: 1.35)
    #expect(abs(spring.resp - 0.55 * 1.35) < 1e-9)
}

@Test func staggerTablesMatchSketch() {
    #expect(FluidStagger.pour[.half] == 0.8)
    #expect(FluidStagger.pour[.run] == 0.9)
    #expect(FluidStagger.pour[.d] == 1.35)
    #expect(FluidStagger.pour[.sd] == 1.35)

    #expect(FluidStagger.drain[.d] == 0.8)
    #expect(FluidStagger.drain[.sd] == 0.8)
    #expect(FluidStagger.drain[.half] == 1.35)
    #expect(FluidStagger.drain[.run] == 1.35)

    #expect(FluidTiming.dwell == 0.25)
    #expect(FluidTiming.intent == 0.14)
    #expect(FluidTiming.lag == 0.12)
    #expect(FluidTiming.contentDelay == 0.16)
    #expect(FluidTiming.pull == 5)
}
