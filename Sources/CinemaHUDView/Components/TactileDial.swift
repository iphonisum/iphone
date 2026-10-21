//
//  TactileDial.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  Cinema tactile rotary dial with visual tick-marks and smooth drag interaction.
//

import SwiftUI

public struct TactileDial: View {
    let title: String
    let valueString: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit: String = ""
    
    @State private var dragOffset: CGFloat = 0
    
    public init(
        title: String,
        valueString: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1.0,
        unit: String = ""
    ) {
        self.title = title
        self.valueString = valueString
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
    }
    
    public var body: some View {
        VStack(spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.yellow.opacity(0.85))
            
            Text(valueString + unit)
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundColor(.white)
            
            // Rotary Dial Visual
            GeometryReader { geo in
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 3)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                    
                    // Tick indicators
                    ForEach(0..<12) { i in
                        Rectangle()
                            .fill(i % 3 == 0 ? Color.yellow : Color.white.opacity(0.4))
                            .frame(width: 1.5, height: i % 3 == 0 ? 8 : 4)
                            .offset(y: -geo.size.width / 2 + 6)
                            .rotationEffect(.degrees(Double(i) * 30.0))
                    }
                    
                    // Rotating Pointer Indicator
                    Rectangle()
                        .fill(Color.yellow)
                        .frame(width: 2.5, height: 12)
                        .offset(y: -geo.size.width / 2 + 10)
                        .rotationEffect(dialAngle)
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { gesture in
                            let translation = -gesture.translation.height + gesture.translation.width
                            let delta = Double(translation) * step * 0.1
                            let newVal = min(max(value + delta, range.lowerBound), range.upperBound)
                            value = (newVal / step).rounded() * step
                        }
                )
            }
            .frame(width: 54, height: 54)
        }
    }
    
    private var dialAngle: Angle {
        let percent = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return .degrees(percent * 270.0 - 135.0)
    }
}
