//
//  LUTBrowserSheet.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  Spatial LUT (.cinemalut) Package Manager & File Importer.
//  Allows importing custom LUT bundles from Files app or USB-C SSD.
//

import SwiftUI
import UniformTypeIdentifiers

public struct LUTBrowserSheet: View {
    @ObservedObject var viewModel: CinemaCameraViewModel
    @Environment(\.dismiss) var dismiss
    @State private var isShowingFilePicker = false
    
    public init(viewModel: CinemaCameraViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        NavigationView {
            ZStack {
                Color(white: 0.1).ignoresSafeArea()
                
                VStack(spacing: 16) {
                    Text("SPATIAL CINEMA LUT BUNDLES")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.yellow)
                        .padding(.top, 10)
                    
                    List {
                        Section(header: Text("AVAILABLE BUNDLES").foregroundColor(.gray)) {
                            ForEach(viewModel.availableBundles, id: \.name) { bundle in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(bundle.name)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.white)
                                        
                                        HStack(spacing: 8) {
                                            Text("Bloom: \(String(format: "%.0f%%", bundle.manifest.glowIntensity * 100))")
                                            Text("•")
                                            Text("Flare: \(String(format: "%.1fx", bundle.manifest.anamorphicStretch))")
                                            Text("•")
                                            Text("Halation: \(String(format: "%.0f%%", bundle.manifest.halationStrength * 100))")
                                        }
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.6))
                                    }
                                    
                                    Spacer()
                                    
                                    if viewModel.activeBundle?.name == bundle.name {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.yellow)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    viewModel.selectLUTBundle(bundle)
                                    dismiss()
                                }
                                .listRowBackground(Color(white: 0.16))
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    
                    Button(action: { isShowingFilePicker = true }) {
                        HStack {
                            Image(systemName: "folder.badge.plus")
                            Text("Import .cinemalut from Files / SSD")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.yellow)
                        .cornerRadius(8)
                        .padding(.horizontal, 20)
                    }
                    .padding(.bottom, 20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundColor(.yellow)
                }
            }
            .fileImporter(
                isPresented: $isShowingFilePicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        do {
                            let bundle = try CinemaLUTBundle.load(from: url, device: viewModel.metalContext.device)
                            viewModel.availableBundles.append(bundle)
                            viewModel.selectLUTBundle(bundle)
                            dismiss()
                        } catch {
                            print("Error importing .cinemalut: \(error.localizedDescription)")
                        }
                    }
                case .failure(let error):
                    print("File picker error: \(error.localizedDescription)")
                }
            }
        }
    }
}
