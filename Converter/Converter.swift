import Foundation
import SwiftyJSON
import RealmSwift

class SaveData: Object {
    dynamic var iso4217 = ""
}

enum Source {
    case File(String)
    case Web(String)
}

enum ConverterError: Error {
    case NotAnISO4217
}

struct Currency {
    var country: String
    var number: Double
}

class Converter {
    typealias ISO4217 = String

    // User preffered currencies
    private var dictionary = [ISO4217 : Currency]()

    // From API
    private var currencies = [ISO4217 : Currency]()

    // Data changed by searchBar
    private var filteredDictionaryAsArray = [(key: ISO4217, value: Currency)]()

    private var koef: Double = 100

    // Number of currencies to show
    var numberOfCurrencies: Int {
        return filteredDictionaryAsArray.count
    }

    var filteredCurrencies: [(country: String, iso4217: ISO4217, on: Bool)] {
        var array = [(country: String, iso4217: ISO4217, on: Bool)]()
        for currency in currencies {

            let x = dictionary.contains { $0.key == currency.key }
            array.insert((currency.value.country, currency.key, on: x), at: array.endIndex)
        }
        return array.sorted(by: { $0.iso4217 < $1.iso4217 })
    }

    // Convert values
    func convert(str: ISO4217, value: Double) {
        let oldValue = currencies[str]!.number
        dictionary.forEach {
            dictionary[$0.key]!.number = currencies[$0.key]!.number * value / oldValue
        }
    }

    // Filter values for searchBar
    func filterChoosenCurrencies(with text: String) {
        guard !text.isEmpty else {
            filteredDictionaryAsArray = dictionary.sorted{ $0.key < $1.key }
            return
        }
        filteredDictionaryAsArray = dictionary.sorted{ $0.key < $1.key }.filter {
            let isISO4217 = $0.key.range(of: text.uppercased()) != nil
            let hasSearchedText = $0.value.country.range(of: text, options: .caseInsensitive,
                                                         range: nil, locale: nil) != nil
            return isISO4217 || hasSearchedText
        }
    }

    // Currency information by index for cell
    func get(with index: Int) -> (country: String, iso4217: ISO4217, number: String){

        let currency = filteredDictionaryAsArray[index]

        var value = currency.value.number
        value = round(value * koef) / koef

        let stringValue = String(value)

        let val = stringValue.components(separatedBy: ".")

        switch val[1] {
        case "0": return (currency.value.country, currency.key, val[0])
        default: return (currency.value.country, currency.key, stringValue)
        }
    }

    // Currency information by ISO4217
    func getRate(with iso4217: ISO4217) throws -> String {
        guard let index = filteredDictionaryAsArray.index(where: { $0.key == iso4217 }) else {
            throw ConverterError.NotAnISO4217
        }
        return get(with: index).number
    }

    // We dont have some of the API currencies, so need to delete them from currencies
    func clear() {
        currencies.removeValue(forKey: "CNH")
        currencies.removeValue(forKey: "GGP")
        currencies.removeValue(forKey: "IMP")
        currencies.removeValue(forKey: "JEP")
        currencies.removeValue(forKey: "XAG")
        currencies.removeValue(forKey: "XAU")
        currencies.removeValue(forKey: "XPD")
        currencies.removeValue(forKey: "XPF")
        currencies.removeValue(forKey: "XPT")
        currencies.removeValue(forKey: "ZMK")
        currencies.removeValue(forKey: "SHP")
    }

    private func getData(from source: Source) -> JSON? {

        var data: Data?

        if case .File(let path) = source {

            guard let text = try? String(contentsOfFile: path) else {
                return nil
            }

            data = text.data(using: .utf8)

        } else if case .Web(let adress) = source {

            guard let url = URL(string: adress) else {
                return nil
            }
            data = try? Data(contentsOf: url)
        }

        guard let dataForJson = data else {
            return nil
        }

        return JSON(data: dataForJson)
    }

    // Delete currency from array by its iso4217
    func deleteCurrency(with iso4217: ISO4217) {

        dictionary.removeValue(forKey: iso4217)

        let index = filteredDictionaryAsArray.index(where: { $0.key == iso4217 })!
        filteredDictionaryAsArray.remove(at: index)

        DispatchQueue(label: "background").async {

            // Realm
            let realm = try! Realm()
            let indexR = realm.objects(SaveData.self).index(where: {$0.iso4217 == iso4217 })
            let value = realm.objects(SaveData.self)[indexR!]

            try! realm.write {

                realm.delete(value)
            }
        }
    }

    // Currency to array from list of currencies by its iso4217
    func addCurrency(with iso4217: ISO4217) {
        dictionary[iso4217] = currencies[iso4217]

        if let currency = dictionary.first(where: { $0.key != iso4217 }) {
            convert(str: currency.key, value: currency.value.number)
        }

        filteredDictionaryAsArray.append((key: iso4217, value: dictionary[iso4217]!))
        filteredDictionaryAsArray.sort(by: { $0.0.key < $0.1.key })

        DispatchQueue(label: "background").async {
            //Realm
            let realm = try! Realm()
            try! realm.write {
                realm.add(SaveData(value: [iso4217]))
            }
        }
    }

    // When app begins reading data
    func loadData() {
        let realm = try! Realm()

        let data = realm.objects(SaveData.self)
        for value in data {
            dictionary[value.iso4217] = currencies[value.iso4217]
        }

        // If we just download the app
        if dictionary.isEmpty {
            let standartPack = ["USD","EUR","RUB","UAH","GBP","AUD"]
            for iso4217 in standartPack {
                dictionary[iso4217] = currencies[iso4217]
                try! realm.write {
                    realm.add(SaveData(value: [iso4217]))
                }
            }
        }
    }

    init?(source: String) {

        // Get data from WEB API

        guard var jsonFromWeb = getData(from: .Web(source)) else {
            return nil
        }

        guard var data = jsonFromWeb["rates"].dictionaryObject as? [String : Double] else {
            return nil
        }

        data[jsonFromWeb["base"].string!] = 1

        for currency in data {
            currencies[currency.key] = Currency(country: "", number: currency.value)
        }

        clear()

        guard let path = Bundle.main.path(forResource: "countries", ofType: "json") else {
            return nil
        }

        guard let jsonFromFile = getData(from: .File(path)) else {
            return nil
        }

        guard let countries = jsonFromFile["rates"].dictionaryObject as? [String : String] else {
            return nil
        }

        currencies.forEach {
            currencies[$0.key]!.country = countries[$0.key] ?? "No Country!"
        }

        loadData()

        filteredDictionaryAsArray = dictionary.sorted { $0.key < $1.key }
    }

}

class ChooseCurrencyModel {
    typealias ISO4217 = String

    private var currencies = [(country: String, iso4217: ISO4217, on: Bool)]()
    var filteredCurrencies = [(country: String, iso4217: ISO4217, on: Bool)]()

    func filter(text: String) {
        filteredCurrencies = text.isEmpty ? currencies : currencies.filter {
            let isISO4217 = $0.iso4217.range(of: text.uppercased()) != nil
            let hasSearchedText = $0.country.range(of: text, options: .caseInsensitive,
                                                   range: nil, locale: nil) != nil
            return isISO4217 || hasSearchedText
        }
    }

    func add(with iso4217: ISO4217) {
        let index = currencies.index(where: { $0.iso4217 == iso4217})!
        currencies[index].on = true
    }

    func delete(with iso4217: ISO4217) {
        let index = currencies.index(where: { $0.iso4217 == iso4217})!
        currencies[index].on = false
    }

    init(currencies: [(country: String, iso4217: ISO4217, on: Bool)]) {
        self.currencies = currencies
        filteredCurrencies = currencies
    }

}



