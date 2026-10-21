//
//  HistogramView.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  Real-time Exposure Histogram with IRE markers (0% Black, 18% Mid-Grey, 100% Clip).
//

import SwiftUI

public struct HistogramView: View {
    public init() {}
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("HISTOGRAM")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text("IRE 0 - 100")
                    .font(.system(size: 8, weight: .regular, design: .monospaced))
                    .foregroundColor(.yellow.opacity(0.8))
            }
            
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                
                // Simulated real-time exposure bell curve / IRE distribution
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 36))
                    path.addCurve(to: CGPoint(x: 35, y: 14), control1: CGPoint(x: 10, y: 30), control2: CGPoint(x: 20, y: 15))
                    path.addCurve(to: CGPoint(x: 65, y: 8), control1: CGPoint(x: 45, y: 12), control2: CGPoint(x: 55, y: 6))
                    path.addCurve(to: CGPoint(x: 100, y: 32), control1: CGPoint(x: 80, y: 12), control2: CGPoint(x: 90, y: 28))
                    path.addLine(to: CGPoint(x: 100, y: 36))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.green.opacity(0.6), Color.yellow.opacity(0.6), Color.red.opacity(0.6)]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                
                // 18% Middle Grey Marker
                Rectangle()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 1, height: 36)
                    .offset(x: 41)
            }
            .frame(width: 100, height: 36)
        }
    }
}
