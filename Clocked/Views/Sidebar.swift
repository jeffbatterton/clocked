import SwiftUI

/// Companies with today's time beside each. Right-click for Edit… and Remove….
struct Sidebar: View {
    @Environment(TimeStore.self) private var store
    @State private var editingID: UUID?
    @State private var adding = false
    @State private var removing: Company?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Companies")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 52)
                .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.companies) { company in
                        row(company)
                    }
                }
                .padding(.horizontal, 10)
            }

            if store.isTestDrive {
                Label("Test drive · sample data", systemImage: "steeringwheel")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .padding(.horizontal, 14)
                    .help("Turn off Test drive in Preferences to get your own data back.")
            }

            Button { adding = true } label: {
                Label("Add company", systemImage: "plus")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .popover(isPresented: $adding, arrowEdge: .trailing) {
                CompanyEditor(company: nil, initialColor: store.randomUnusedColorIndex()) { adding = false }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
        .alert(
            "Remove “\(removing?.name ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { company in
            Button("Remove", role: .destructive) { store.removeCompany(company.id) }
            Button("Cancel", role: .cancel) {}
        } message: { company in
            Text(removeMessage(for: company))
        }
    }

    private func row(_ company: Company) -> some View {
        let isSelected = company.id == store.selectedCompanyID
        let isRunning = store.running(for: company.id) != nil
        let today = store.actualTotal(for: company.id, on: store.currentDay(for: company.id))

        return Button { store.selectedCompanyID = company.id } label: {
            HStack(spacing: 9) {
                CompanyDot(company: company)
                Text(company.name).lineLimit(1)
                Spacer(minLength: 4)
                Text(TimeFormat.clock(today))
                    .font(.system(size: 12, weight: isRunning ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isRunning ? Theme.live : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(isSelected ? Theme.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit…") { editingID = company.id }
            Divider()
            Button("Remove…", role: .destructive) { removing = company }
        }
        .popover(
            isPresented: Binding(get: { editingID == company.id }, set: { if !$0 { editingID = nil } }),
            arrowEdge: .trailing
        ) {
            CompanyEditor(company: company, initialColor: company.colorIndex) { editingID = nil }
        }
    }

    private func removeMessage(for company: Company) -> String {
        let hours = Int(store.dailyTotals(for: company.id).values.reduce(0, +) / 3600)
        let logged = switch hours {
        case 0: "Its logged time will be deleted."
        case 1: "Its 1 hour of logged time will be deleted."
        default: "Its \(hours) hours of logged time will be deleted."
        }
        return logged + " This can't be undone."
    }
}

/// Name and colour for a new or existing company. Colours other companies use are faded.
struct CompanyEditor: View {
    let company: Company?
    var onDone: () -> Void

    @Environment(TimeStore.self) private var store
    @State private var name: String
    @State private var colorIndex: Int

    init(company: Company?, initialColor: Int, onDone: @escaping () -> Void) {
        self.company = company
        self.onDone = onDone
        _name = State(initialValue: company?.name ?? "")
        _colorIndex = State(initialValue: initialColor)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let used = Set(store.companies.filter { $0.id != company?.id }.map(\.colorIndex))

        VStack(alignment: .leading, spacing: 10) {
            Text(company == nil ? "New company" : "Edit company")
                .font(.system(size: 13, weight: .semibold))
            TextField("Company name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text("Color")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 12), count: 6), spacing: 10) {
                ForEach(Array(Palette.indices), id: \.self) { index in
                    Button { colorIndex = index } label: {
                        Circle()
                            .fill(Palette.color(index))
                            .opacity(used.contains(index) && index != colorIndex ? 0.35 : 1)
                            .frame(width: 24, height: 24)
                            .padding(3)
                            .overlay {
                                if index == colorIndex {
                                    Circle().strokeBorder(Color.primary, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button(company == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 260)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        if var company {
            company.name = trimmedName
            company.colorIndex = colorIndex
            store.updateCompany(company)
        } else {
            store.addCompany(name: trimmedName, colorIndex: colorIndex)
        }
        onDone()
    }
}
