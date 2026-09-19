import SwiftUI
import SwiftData

struct FundraiserListView: View {
    @Query(sort: \FundraiserRecord.createdAt, order: .reverse) private var fundraisers: [FundraiserRecord]
    @State private var showingNew = false
    @State private var showArchived = false
    var body: some View {
        List {
            Toggle("Show archived fundraisers", isOn: $showArchived)
            ForEach(fundraisers.filter { showArchived || !$0.isArchived }) { fundraiser in
                NavigationLink {
                    FundraiserDetailView(fundraiser: fundraiser)
                } label: {
                    VStack(alignment: .leading) {
                        Text(fundraiser.name).font(.headline)
                        Text(fundraiser.isArchived ? "Archived" : "Active").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if fundraisers.isEmpty {
                ContentUnavailableView("Product Fundraisers", systemImage: "shippingbox", description: Text("Track candy bars, popcorn, wreaths, and other products from bulk purchase through sales and money turned in."))
            }
        }
        .navigationTitle("Fundraisers")
        .toolbar { Button("New Fundraiser", systemImage: "plus") { showingNew = true } }
        .sheet(isPresented: $showingNew) { FundraiserSetupView(fundraiser: nil) }
    }
}

private struct FundraiserSetupView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let fundraiser: FundraiserRecord?
    @State private var name = ""
    @State private var notes = ""
    @State private var unit = "bar"
    @State private var cost = ""
    @State private var price = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField(fundraiser == nil ? "Fundraiser name" : "Product or lot name", text: $name)
                if fundraiser != nil {
                    TextField("Selling unit (bar, bag, box)", text: $unit)
                    TextField("Cost per selling unit", text: $cost)
                    TextField("Default price per selling unit", text: $price)
                    Text("For a case of 60 bars costing $30, use bar as the unit and $0.50 as the cost. Receive 60 units per case. Add a separate product/lot when the cost changes.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle(fundraiser == nil ? "New Fundraiser" : "Add Product")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            if let fundraiser {
                                guard let c = Money.cents(from: cost), let p = Money.cents(from: price) else { throw FundraiserError(message: "Enter valid cost and price amounts.") }
                                try FundraiserService.addProduct(to: fundraiser, name: name, unit: unit, cost: c, price: p, in: context)
                            } else {
                                try FundraiserService.create(name: name, notes: notes, in: context)
                            }
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 340, minHeight: 350)
    }
}

private struct FundraiserDetailView: View {
    @Environment(\.modelContext) private var context
    let fundraiser: FundraiserRecord
    @Query private var allProducts: [FundraiserProductRecord]
    @Query private var allActivities: [FundraiserActivityRecord]
    @Query(sort: \PersonRecord.lastName) private var people: [PersonRecord]
    @State private var showingProduct = false
    @State private var showingActivity = false
    @State private var voiding: FundraiserActivityRecord?
    @State private var error: String?
    private var products: [FundraiserProductRecord] { allProducts.filter { $0.fundraiserID == fundraiser.id }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private var activities: [FundraiserActivityRecord] { allActivities.filter { $0.fundraiserID == fundraiser.id } }
    private var total: FundraiserBalance { FundraiserService.balance(activities) }
    private var purchaseCost: Int64 { activities.filter { $0.voidedAt == nil && $0.kindRaw == FundraiserActivityKind.receive.rawValue }.reduce(0) { $0 + $1.amountCents } }
    private func costOfSales(personID: UUID? = nil) -> Int64 {
        products.reduce(0) { sum, product in
            sum + FundraiserService.balance(activities.filter { $0.productID == product.id }, personID: personID).sold * product.unitCostCents
        }
    }
    private var sellerIDs: [UUID] {
        Set(activities.compactMap(\.personID)).sorted { sellerName($0) < sellerName($1) }
    }
    private func sellerName(_ id: UUID) -> String {
        people.first { $0.id == id }?.displayName ?? activities.first { $0.personID == id }?.sellerName ?? "Former member"
    }
    var body: some View {
        List {
            Section("Fundraiser Summary") {
                if !fundraiser.notes.isEmpty { Text(fundraiser.notes) }
                LabeledContent("Sales revenue", value: Money.currency(cents: total.revenue))
                LabeledContent("Gross profit on sold products", value: Money.currency(cents: total.revenue - costOfSales()))
                LabeledContent("Stock purchased", value: Money.currency(cents: purchaseCost))
                LabeledContent("Sales less all stock purchases", value: Money.currency(cents: total.revenue - purchaseCost))
                LabeledContent("Money turned in", value: Money.currency(cents: total.turnedIn))
                LabeledContent("Still to turn in", value: Money.currency(cents: total.outstanding))
                Text("Sales are paid sales. Gross profit excludes unsold stock, losses, and other expenses. Purchases and money turned in are tracking records; enter the corresponding expenses and receipts in Transactions to update the troop’s books.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Products & Inventory") {
                ForEach(products) { product in
                    let balance = FundraiserService.balance(activities.filter { $0.productID == product.id })
                    VStack(alignment: .leading, spacing: 5) {
                        Text(product.name).font(.headline)
                        Text("Unit: \(product.unitName) • Cost \(Money.currency(cents: product.unitCostCents)) • Price \(Money.currency(cents: product.unitPriceCents))").font(.caption)
                        Text("Received \(balance.received) • Troop stock \(balance.available) • With sellers \(balance.onHand) • Sold \(balance.sold) • Lost/damaged \(balance.lost)")
                            .font(.subheadline)
                    }
                }
                if !fundraiser.isArchived {
                    Button("Add Product", systemImage: "plus") { showingProduct = true }
                }
            }
            Section("Scouts & Leaders") {
                if sellerIDs.isEmpty { Text("Issue product to a person from your People list to begin tracking their sales.").foregroundStyle(.secondary) }
                ForEach(sellerIDs, id: \.self) { id in
                    let balance = FundraiserService.balance(activities, personID: id)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sellerName(id)).font(.headline)
                        ForEach(products.filter { product in activities.contains { $0.productID == product.id && $0.personID == id && $0.voidedAt == nil } }) { product in
                            let productBalance = FundraiserService.balance(activities.filter { $0.productID == product.id }, personID: id)
                            Text("\(product.name): \(productBalance.onHand) on hand • \(productBalance.sold) sold • \(productBalance.lost) lost/damaged").font(.subheadline)
                        }
                        Text("Sales \(Money.currency(cents: balance.revenue)) • Gross profit \(Money.currency(cents: balance.revenue - costOfSales(personID: id)))").font(.subheadline)
                        Text("Turned in \(Money.currency(cents: balance.turnedIn)) • Still owed \(Money.currency(cents: balance.outstanding))").font(.subheadline).bold()
                    }.padding(.vertical, 4)
                }
            }
            Section("Activity History") {
                ForEach(activities.sorted { $0.date == $1.date ? $0.createdAt > $1.createdAt : $0.date > $1.date }) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(row.kindRaw)\(row.voidedAt == nil ? "" : " — VOID")").font(.headline)
                        Text("\(allProducts.first { $0.id == row.productID }?.name ?? "Unknown product") • \(row.sellerName)")
                        Text("\(row.date.formatted(date: .abbreviated, time: .shortened)) • \(row.quantity) units • \(Money.currency(cents: row.amountCents))").font(.caption)
                        if !row.notes.isEmpty { Text(row.notes).font(.caption) }
                        if row.voidedAt != nil { Text("Reason: \(row.voidReason)").font(.caption) }
                        else if !fundraiser.isArchived { Button("Void…", role: .destructive) { voiding = row }.font(.caption) }
                    }.foregroundStyle(row.voidedAt == nil ? Color.primary : Color.secondary)
                }
            }
            Section {
                Button(fundraiser.isArchived ? "Reopen Fundraiser" : "Archive Fundraiser") {
                    do { try FundraiserService.setArchived(fundraiser, in: context) } catch { self.error = error.localizedDescription }
                }
            }
        }
        .navigationTitle(fundraiser.name)
        .toolbar {
            if !fundraiser.isArchived {
                Button("Record Activity", systemImage: "plus.circle") { showingActivity = true }.disabled(products.isEmpty)
            }
        }
        .sheet(isPresented: $showingProduct) { FundraiserSetupView(fundraiser: fundraiser) }
        .sheet(isPresented: $showingActivity) { FundraiserActivityEditor(fundraiser: fundraiser, products: products, people: people) }
        .sheet(item: $voiding) { row in FundraiserVoidView(row: row) }
        .alert("Fundraiser", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
}

private struct FundraiserActivityEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let fundraiser: FundraiserRecord
    let products: [FundraiserProductRecord]
    let people: [PersonRecord]
    @State private var kind: FundraiserActivityKind = .receive
    @State private var productID: UUID?
    @State private var personID: UUID?
    @State private var quantity = ""
    @State private var amount = ""
    @State private var date = Date()
    @State private var notes = ""
    @State private var error: String?
    private var product: FundraiserProductRecord? { products.first { $0.id == productID } }
    private var saleDefault: Int64? {
        guard let q = Int64(quantity), q > 0, q <= 1_000_000, let product else { return nil }
        let value = q.multipliedReportingOverflow(by: product.unitPriceCents)
        return value.overflow || value.partialValue > Money.maximumCents ? nil : value.partialValue
    }
    var body: some View {
        NavigationStack {
            Form {
                Picker("Activity", selection: $kind) { ForEach(FundraiserActivityKind.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Product", selection: $productID) {
                    Text("Choose product").tag(nil as UUID?)
                    ForEach(products) { Text($0.name).tag(Optional($0.id)) }
                }
                if kind.needsSeller {
                    Picker("Seller", selection: $personID) {
                        Text("Choose seller").tag(nil as UUID?)
                        ForEach(people) { Text("\($0.displayName) (\($0.role.rawValue))\($0.isActive ? "" : " — inactive")").tag(Optional($0.id)) }
                    }
                }
                if kind.needsQuantity { TextField("Quantity in selling units", text: $quantity) }
                if kind == .receive { Text("Enter individual selling units, e.g. 120 bars for two cases of 60.").font(.footnote) }
                if kind == .sale || kind == .remittance {
                    TextField(kind == .sale ? "Total sale amount (blank = default price)" : "Amount turned in for this product", text: $amount)
                    if kind == .sale, let saleDefault { LabeledContent("Default sale total", value: Money.currency(cents: saleDefault)) }
                }
                DatePicker("Date", selection: $date, in: ...Date())
                TextField("Notes / receipt reference", text: $notes, axis: .vertical)
                if kind == .sale { Text("Record completed, paid sales. Record money turned in separately when the treasurer receives it.").font(.footnote) }
                if kind == .remittance { Text("For a payment covering several products, record each product’s share separately. This does not create a transaction in the troop’s books.").font(.footnote) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("Record Activity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(product == nil || (kind.needsSeller && personID == nil))
                }
            }
            .onAppear { if productID == nil { productID = products.first?.id } }
        }.frame(minWidth: 350, minHeight: 460)
    }
    private func save() {
        do {
            guard let product else { return }
            let value: Int64
            if kind == .sale || kind == .remittance {
                guard let parsed = amount.trimmingCharacters(in: .whitespaces).isEmpty && kind == .sale ? saleDefault : Money.cents(from: amount) else { throw FundraiserError(message: "Enter a valid amount and quantity.") }
                value = parsed
            } else { value = 0 }
            try FundraiserService.record(fundraiser: fundraiser, product: product, person: people.first { $0.id == personID }, kind: kind,
                quantity: Int64(quantity) ?? 0, amount: value, date: date, notes: notes, in: context)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct FundraiserVoidView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let row: FundraiserActivityRecord
    @State private var reason = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Text("Void \(row.kindRaw.lowercased()) for \(row.sellerName)? The original remains in the history. If later activity depends on it, void that activity first.")
                TextField("Correction reason", text: $reason, axis: .vertical)
                if let error { Text(error).foregroundStyle(.red) }
            }.formStyle(.grouped)
            .navigationTitle("Void Activity")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Void", role: .destructive) {
                        do { try FundraiserService.void(row, reason: reason, in: context); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.frame(minWidth: 340, minHeight: 260)
    }
}
