#if os(iOS) || os(macOS)
import Contacts
import Foundation
import Nanocode

extension DeviceKit {
  static let contactActions = ["search", "get", "list", "create", "update", "delete", "groups", "group_members", "group_create", "group_rename",
                               "group_delete", "group_add", "group_remove", "containers"]

  static let contacts = HostTool(
    name: "contacts",
    description: "The owner's contacts on this \(DeviceTools.here) (every account added to iOS). search: by name, or by phone, email, organization or any text with query. get: one by id. list: everyone in the owner's order. create, update (only the fields given; a list given replaces that list), delete. groups, group_members, group_create, group_rename, group_delete, group_add and group_remove manage groups; containers lists the accounts.",
    parameters: schema(contactActions, paged(contactProperties))
  ) { call in try await addressBook(call.input) }

  static let contactProperties: [String: JSON] = [
    "query": prop("string", "For search: a name, or text matched against organizations, job titles, emails, phones and handles."),
    "phone": prop("string", "For search: a phone number."),
    "email": prop("string", "For search: an email address."),
    "id": prop("string", "A contact id (get, update, delete)."),
    "ids": list(prop("string"), "Contact ids (group_add, group_remove)."),
    "group": prop("string", "A group id or name (search, list, group_members, group_rename, group_delete, group_add, group_remove)."),
    "name": prop("string", "For group_create and group_rename: the group's name."),
    "container": prop("string", "For create and group_create: a container id from containers; the default otherwise."),
    "given_name": prop("string"), "middle_name": prop("string"), "family_name": prop("string"), "nickname": prop("string"),
    "organization": prop("string"), "department": prop("string"), "job_title": prop("string"),
    "birthday": prop("string", "yyyy-mm-dd, or --mm-dd without a year; an empty string clears it."),
    "phones": list(entry(["label", "value"]), "Labels: mobile, iphone, home, work, main, other, or any text."),
    "emails": list(entry(["label", "value"])),
    "urls": list(entry(["label", "value"])),
    "addresses": list(entry(["label", "street", "city", "state", "postal_code", "country", "country_code"])),
    "social": list(entry(["service", "username"]), "Profiles such as x, linkedin, facebook, or any service name."),
    "messaging": list(entry(["service", "username"]), "Instant messaging handles such as WhatsApp, Telegram or Signal."),
    "relations": list(entry(["label", "value"]), "Related people, labelled spouse, child, parent, friend, assistant, manager or any text."),
  ]

  static var contactKeys: [CNKeyDescriptor] {
    [CNContactIdentifierKey, CNContactTypeKey, CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
     CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
     CNContactUrlAddressesKey, CNContactPostalAddressesKey, CNContactBirthdayKey, CNContactSocialProfilesKey,
     CNContactInstantMessageAddressesKey, CNContactRelationsKey, CNContactImageDataAvailableKey] as [CNKeyDescriptor]
      + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
  }

  static func addressBook(_ input: JSON) async throws -> ToolResult {
    try await DeviceTools.gate("contacts")
    let store = CNContactStore()
    switch input["action"]?.string {
    case "search":
      var found = try searchContacts(store, input)
      if let group = text(input, "group"), text(input, "query") != nil {
        let target = try findGroup(store, group)
        let members = Set(try store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: target.identifier),
                                                    keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]).map(\.identifier))
        found = found.filter { members.contains($0.identifier) }
      }
      return .json(try page(found.map(describe), input, 50, most: 5000))
    case "get":
      return .json(describe(try contact(store, try need(input, "id", for: "get"))))
    case "list":
      var found: [JSON] = []
      if let group = text(input, "group") {
        let target = try findGroup(store, group)
        found = try store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: target.identifier), keysToFetch: contactKeys)
          .map(describe)
      } else {
        let request = CNContactFetchRequest(keysToFetch: contactKeys)
        request.sortOrder = .userDefault
        try store.enumerateContacts(with: request) { contact, _ in found.append(describe(contact)) }
      }
      return .json(try page(found, input, 50, most: 5000))
    case "create":
      let created = CNMutableContact()
      try apply(input, to: created)
      guard !(created.givenName + created.familyName + created.organizationName + created.nickname).isEmpty else {
        throw NanocodeError("create takes a name, a nickname or an organization")
      }
      let request = CNSaveRequest()
      request.add(created, toContainerWithIdentifier: text(input, "container"))
      try store.execute(request)
      return .json(describe(try contact(store, created.identifier)))
    case "update":
      guard let existing = try contact(store, try need(input, "id", for: "update")).mutableCopy() as? CNMutableContact else {
        throw NanocodeError("that contact can't be edited")
      }
      try apply(input, to: existing)
      let request = CNSaveRequest()
      request.update(existing)
      try store.execute(request)
      return .json(describe(try contact(store, existing.identifier)))
    case "delete":
      let id = try need(input, "id", for: "delete")
      guard let existing = try contact(store, id).mutableCopy() as? CNMutableContact else { throw NanocodeError("that contact can't be deleted") }
      let name = CNContactFormatter.string(from: existing, style: .fullName) ?? ""
      let request = CNSaveRequest()
      request.delete(existing)
      try store.execute(request)
      return .json(["deleted": .string(id), "name": .string(name)])
    case "groups":
      let groups = try store.groups(matching: nil)
      return .json(.array(try groups.map { group in
        let members = try store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: group.identifier),
                                                keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
        return ["id": .string(group.identifier), "name": .string(group.name), "members": .number(Double(members.count))]
      }))
    case "group_members":
      let target = try findGroup(store, try need(input, "group", for: "group_members"))
      let members = try store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: target.identifier), keysToFetch: contactKeys)
      return .json(try page(members.map(describe), input, 50, most: 5000))
    case "group_create":
      let group = CNMutableGroup()
      group.name = try need(input, "name", for: "group_create")
      let request = CNSaveRequest()
      request.add(group, toContainerWithIdentifier: text(input, "container"))
      try store.execute(request)
      return .json(["id": .string(group.identifier), "name": .string(group.name)])
    case "group_rename":
      guard let group = try findGroup(store, try need(input, "group", for: "group_rename")).mutableCopy() as? CNMutableGroup else {
        throw NanocodeError("that group can't be renamed")
      }
      group.name = try need(input, "name", for: "group_rename")
      let request = CNSaveRequest()
      request.update(group)
      try store.execute(request)
      return .json(["id": .string(group.identifier), "name": .string(group.name)])
    case "group_delete":
      guard let group = try findGroup(store, try need(input, "group", for: "group_delete")).mutableCopy() as? CNMutableGroup else {
        throw NanocodeError("that group can't be deleted")
      }
      let request = CNSaveRequest()
      request.delete(group)
      try store.execute(request)
      return .json(["deleted": .string(group.identifier), "name": .string(group.name)])
    case "group_add", "group_remove":
      let action = input["action"]?.string ?? ""
      let target = try findGroup(store, try need(input, "group", for: action))
      let ids = texts(input, "ids")
      guard !ids.isEmpty else { throw NanocodeError("\(action) takes ids") }
      let members = try store.unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers: ids), keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
      let missing = Set(ids).subtracting(members.map(\.identifier))
      guard missing.isEmpty else { throw NanocodeError("no contact has the id \(missing.sorted().joined(separator: ", "))") }
      let request = CNSaveRequest()
      for member in members {
        if action == "group_add" { request.addMember(member, to: target) } else { request.removeMember(member, from: target) }
      }
      try store.execute(request)
      let key = action == "group_add" ? "added" : "removed"
      return .json(.object(["group": .string(target.name), key: .array(ids.map(JSON.string))]))
    case "containers":
      let fallback = store.defaultContainerIdentifier()
      return .json(.array(try store.containers(matching: nil).map { container in
        let kind = switch container.type {
        case .local: "local"
        case .exchange: "exchange"
        case .cardDAV: "carddav"
        default: "other"
        }
        return ["id": .string(container.identifier), "name": .string(container.name), "type": .string(kind),
                "default": .bool(container.identifier == fallback)]
      }))
    default:
      throw unknown("contacts", contactActions)
    }
  }

  static func contact(_ store: CNContactStore, _ id: String) throws -> CNContact {
    guard let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers: [id]), keysToFetch: contactKeys).first else {
      throw NanocodeError("no contact has the id \(id)")
    }
    return found
  }

  static func findGroup(_ store: CNContactStore, _ key: String) throws -> CNGroup {
    let groups = try store.groups(matching: nil)
    if let found = groups.first(where: { $0.identifier == key }) ?? groups.first(where: { $0.name.localizedCaseInsensitiveCompare(key) == .orderedSame }) {
      return found
    }
    throw NanocodeError("no contact group is called \(key); groups lists them")
  }

  static func searchContacts(_ store: CNContactStore, _ input: JSON) throws -> [CNContact] {
    if let phone = text(input, "phone") {
      return try store.unifiedContacts(matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: phone)), keysToFetch: contactKeys)
    }
    if let email = text(input, "email") {
      return try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: email), keysToFetch: contactKeys)
    }
    if let group = text(input, "group"), text(input, "query") == nil {
      let target = try findGroup(store, group)
      return try store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: target.identifier), keysToFetch: contactKeys)
    }
    guard let query = text(input, "query") else { throw NanocodeError("search takes a query, a phone or an email") }
    let named = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: query), keysToFetch: contactKeys)
    var seen = Set(named.map(\.identifier))
    var found = named
    let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split(separator: " ").map(String.init)
    let digits = query.filter(\.isNumber)
    let request = CNContactFetchRequest(keysToFetch: contactKeys)
    try store.enumerateContacts(with: request) { contact, _ in
      guard !seen.contains(contact.identifier) else { return }
      let haystack = searchText(contact)
      let phoneMatch = digits.count >= 4 && contact.phoneNumbers.contains { $0.value.stringValue.filter(\.isNumber).contains(digits) }
      if phoneMatch || words.allSatisfy({ haystack.contains($0) }) {
        seen.insert(contact.identifier)
        found.append(contact)
      }
    }
    return found
  }

  static func searchText(_ contact: CNContact) -> String {
    let parts = [contact.givenName, contact.middleName, contact.familyName, contact.nickname, contact.organizationName, contact.departmentName,
                 contact.jobTitle] + contact.emailAddresses.map { $0.value as String } + contact.urlAddresses.map { $0.value as String }
      + contact.socialProfiles.map(\.value.username) + contact.instantMessageAddresses.map(\.value.username)
      + contact.postalAddresses.map { [$0.value.city, $0.value.country, $0.value.street].joined(separator: " ") }
    return parts.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }

  static func label(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
    switch text {
    case "mobile", "cell": return CNLabelPhoneNumberMobile
    case "iphone": return CNLabelPhoneNumberiPhone
    case "main": return CNLabelPhoneNumberMain
    case "home": return CNLabelHome
    case "work": return CNLabelWork
    case "school": return CNLabelSchool
    case "other": return CNLabelOther
    case "homepage": return CNLabelURLAddressHomePage
    case "spouse": return CNLabelContactRelationSpouse
    case "child": return CNLabelContactRelationChild
    case "parent": return CNLabelContactRelationParent
    case "mother": return CNLabelContactRelationMother
    case "father": return CNLabelContactRelationFather
    case "sibling": return CNLabelContactRelationSibling
    case "friend": return CNLabelContactRelationFriend
    case "partner": return CNLabelContactRelationPartner
    case "assistant": return CNLabelContactRelationAssistant
    case "manager": return CNLabelContactRelationManager
    default: return text
    }
  }

  static func entries(_ value: JSON?, _ fallback: String?) -> [(label: String?, value: String)]? {
    guard let list = value?.array else { return nil }
    return list.compactMap { item in
      if let text = item.string { return text.isEmpty ? nil : (fallback, text) }
      guard let text = (item["value"] ?? item["number"] ?? item["address"])?.string, !text.isEmpty else { return nil }
      return (label(item["label"]?.string) ?? fallback, text)
    }
  }

  static func apply(_ input: JSON, to contact: CNMutableContact) throws {
    if let value = input["given_name"]?.string { contact.givenName = value }
    if let value = input["middle_name"]?.string { contact.middleName = value }
    if let value = input["family_name"]?.string { contact.familyName = value }
    if let value = input["nickname"]?.string { contact.nickname = value }
    if let value = input["organization"]?.string { contact.organizationName = value }
    if let value = input["department"]?.string { contact.departmentName = value }
    if let value = input["job_title"]?.string { contact.jobTitle = value }
    if let birthday = input["birthday"]?.string {
      contact.birthday = birthday.isEmpty ? nil : try components(birthday)
    }
    if let phones = entries(input["phones"], CNLabelPhoneNumberMobile) {
      contact.phoneNumbers = phones.map { CNLabeledValue(label: $0.label, value: CNPhoneNumber(stringValue: $0.value)) }
    }
    if let emails = entries(input["emails"], CNLabelHome) {
      contact.emailAddresses = emails.map { CNLabeledValue(label: $0.label, value: $0.value as NSString) }
    }
    if let urls = entries(input["urls"], CNLabelURLAddressHomePage) {
      contact.urlAddresses = urls.map { CNLabeledValue(label: $0.label, value: $0.value as NSString) }
    }
    if let relations = entries(input["relations"], CNLabelOther) {
      contact.contactRelations = relations.map { CNLabeledValue(label: $0.label, value: CNContactRelation(name: $0.value)) }
    }
    if let addresses = input["addresses"]?.array {
      contact.postalAddresses = addresses.map { item in
        let address = CNMutablePostalAddress()
        address.street = item["street"]?.string ?? ""
        address.city = item["city"]?.string ?? ""
        address.state = item["state"]?.string ?? ""
        address.postalCode = item["postal_code"]?.string ?? ""
        address.country = item["country"]?.string ?? ""
        address.isoCountryCode = item["country_code"]?.string ?? ""
        return CNLabeledValue(label: label(item["label"]?.string) ?? CNLabelHome, value: address.copy() as! CNPostalAddress)
      }
    }
    if let social = input["social"]?.array {
      contact.socialProfiles = social.compactMap { item in
        guard let username = item["username"]?.string, !username.isEmpty else { return nil }
        let service = item["service"]?.string ?? ""
        let known = switch service.lowercased() {
        case "x", "twitter": CNSocialProfileServiceTwitter
        case "linkedin": CNSocialProfileServiceLinkedIn
        case "facebook": CNSocialProfileServiceFacebook
        case "flickr": CNSocialProfileServiceFlickr
        default: service
        }
        return CNLabeledValue(label: nil, value: CNSocialProfile(urlString: nil, username: username, userIdentifier: nil, service: known))
      }
    }
    if let messaging = input["messaging"]?.array {
      contact.instantMessageAddresses = messaging.compactMap { item in
        guard let username = item["username"]?.string, !username.isEmpty else { return nil }
        return CNLabeledValue(label: nil, value: CNInstantMessageAddress(username: username, service: item["service"]?.string ?? ""))
      }
    }
  }

  static func components(_ text: String) throws -> DateComponents {
    let parts = text.split(separator: "-", omittingEmptySubsequences: true).compactMap { Int($0) }
    if text.hasPrefix("--"), parts.count == 2 { return DateComponents(month: parts[0], day: parts[1]) }
    if parts.count == 3 { return DateComponents(year: parts[0], month: parts[1], day: parts[2]) }
    throw NanocodeError("birthday takes yyyy-mm-dd or --mm-dd")
  }

  static func describe(_ contact: CNContact) -> JSON {
    func labelled(_ label: String?) -> JSON { .string(CNLabeledValue<NSString>.localizedString(forLabel: label ?? "")) }
    var object: [String: JSON] = [
      "id": .string(contact.identifier),
      "name": .string(CNContactFormatter.string(from: contact, style: .fullName) ?? ""),
      "type": .string(contact.contactType == .organization ? "organization" : "person"),
      "phones": .array(contact.phoneNumbers.map { ["label": labelled($0.label), "value": .string($0.value.stringValue)] }),
      "emails": .array(contact.emailAddresses.map { ["label": labelled($0.label), "value": .string($0.value as String)] }),
      "has_image": .bool(contact.imageDataAvailable),
    ]
    for (key, value) in [("given_name", contact.givenName), ("middle_name", contact.middleName), ("family_name", contact.familyName),
                         ("nickname", contact.nickname), ("organization", contact.organizationName), ("department", contact.departmentName),
                         ("job_title", contact.jobTitle)] where !value.isEmpty {
      object[key] = .string(value)
    }
    if !contact.urlAddresses.isEmpty {
      object["urls"] = .array(contact.urlAddresses.map { ["label": labelled($0.label), "value": .string($0.value as String)] })
    }
    if !contact.postalAddresses.isEmpty {
      object["addresses"] = .array(contact.postalAddresses.map { entry in
        let address = entry.value
        return ["label": labelled(entry.label), "street": .string(address.street), "city": .string(address.city), "state": .string(address.state),
                "postal_code": .string(address.postalCode), "country": .string(address.country),
                "formatted": .string(CNPostalAddressFormatter.string(from: address, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", "))]
      })
    }
    if !contact.socialProfiles.isEmpty {
      object["social"] = .array(contact.socialProfiles.map { ["service": .string($0.value.service), "username": .string($0.value.username)] })
    }
    if !contact.instantMessageAddresses.isEmpty {
      object["messaging"] = .array(contact.instantMessageAddresses.map { ["service": .string($0.value.service), "username": .string($0.value.username)] })
    }
    if !contact.contactRelations.isEmpty {
      object["relations"] = .array(contact.contactRelations.map { ["label": labelled($0.label), "value": .string($0.value.name)] })
    }
    if let birthday = contact.birthday, let month = birthday.month, let day = birthday.day {
      object["birthday"] = .string(birthday.year.map { String(format: "%04d-%02d-%02d", $0, month, day) } ?? String(format: "--%02d-%02d", month, day))
    }
    return .object(object)
  }
}
#endif
