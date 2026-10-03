import Foundation
import Dispatch
import SQLiteData
import GRDB
import DispatchHost
@Table struct Item: Equatable, Sendable { let id: Int; var title: String; var count: Int }
@Table struct CodecItem: Equatable, Sendable { let id: UUID; var createdAt: Date; var large: Int64; var payload: Data? }
@DatabaseFunction func fixtureSum(_ values: some Sequence<Int>) -> Int { values.reduce(0,+) }
@DatabaseFunction func fixtureExclaim(_ text: String) -> String { text + "!" }
func check(_ value:Bool,_ name:String){precondition(value,name);print("PASS \(name)")}
func pump(){for _ in 0..<8{_ = fixture_dispatch_pump()}}
final class Box<T>: @unchecked Sendable {var value:T;init(_ value:T){self.value=value}}
fixture_dispatch_register()
var config=Configuration();config.prepareDatabase { db in db.add(function:$fixtureSum);db.add(function:$fixtureExclaim) }
let queue=try DatabaseQueue(configuration:config)
try queue.write { db in
 try db.execute(sql:"CREATE TABLE items(id INTEGER PRIMARY KEY,title TEXT NOT NULL,count INTEGER NOT NULL)")
 try Item.insert { Item(id:1,title:"日本語",count:5) }.execute(db)
 try Item.insert { Item(id:2,title:"Second",count:7) }.execute(db)
}
let record=CodecItem(id:UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,createdAt:Date(timeIntervalSince1970:1728000.125),large:Int64.max-17,payload:Data([0,1,255]))
try queue.write { db in
 try db.execute(sql:"CREATE TABLE codecItems(id TEXT PRIMARY KEY,createdAt TEXT NOT NULL,large INTEGER NOT NULL,payload BLOB)")
 try CodecItem.insert {record}.execute(db)
}
let decoded=try queue.read {try CodecItem.fetchOne($0)}
check(decoded == record,"typed UUID/date/blob/near-max Int64 roundtrip")
try queue.write { db in try CodecItem.update {$0.payload = #bind(Optional<Data>.none)}.execute(db) }
check(try queue.read {try CodecItem.fetchOne($0)?.payload} == nil,"typed nullable blob")
let fetched=FetchAll<Item>(Item.order(by:\.id),database:queue)
check(fetched.wrappedValue.map(\.count) == [5,7] && fetched.loadError == nil,"SQLiteData FetchAll initial subscription")
let items=try queue.read {try Item.order(by:\.id).fetchAll($0)}
check(items == [Item(id:1,title:"日本語",count:5),Item(id:2,title:"Second",count:7)],"SQLiteData typed insert/fetch")
try queue.write { db in try Item.where {$0.id.eq(1)}.update {$0.count = 6}.execute(db) }
check(try queue.read {try Item.where {$0.id.eq(1)}.fetchOne($0)?.count} == 6,"typed bound update")
pump();check(fetched.wrappedValue.map(\.count) == [6,7],"SQLiteData FetchAll reactive update")
try queue.inTransaction {db in try Item.where {$0.id.eq(1)}.update {$0.count = 99}.execute(db);return .rollback}
check(try queue.read {try Item.where {$0.id.eq(1)}.fetchOne($0)?.count} == 6,"typed rollback")
let scalar=try queue.read {try Item.where {$0.id.eq(1)}.select {$fixtureExclaim($0.title)}.fetchOne($0)}
check(scalar == "日本語!","SQLiteData scalar function")
let values=Box<[Int]>([]),errors=Box<[String]>([])
let observation=ValueObservation.tracking { db in try Item.order(by:\.id).fetchAll(db).map(\.count) }
let token=observation.start(in:queue,scheduling:.async(onQueue:DispatchQueue(label:"fixture-sqlitedata-notify")),onError:{errors.value.append(String(describing:$0))},onChange:{values.value.append($0[0])})
pump();check(values.value == [6],"typed observation initial")
try queue.write {db in try Item.where {$0.id.eq(1)}.update {$0.count = 8}.execute(db)};pump();check(values.value == [6,8],"typed observation after commit")
try queue.inTransaction { db in try Item.where {$0.id.eq(1)}.update {$0.count = 999}.execute(db);return .rollback };pump();check(values.value == [6,8],"typed rollback no notification")
token.cancel();try queue.write {db in try Item.where {$0.id.eq(1)}.update {$0.count = 9}.execute(db)};pump();check(values.value == [6,8] && errors.value.isEmpty,"typed observation cancellation")
check(fetched.wrappedValue.map(\.count) == [9,7] && fetched.loadError == nil,"SQLiteData FetchAll non-Combine path")
print("BEGIN_AGGREGATE_SYNC")
let sum=try queue.read {try Item.select {$fixtureSum($0.count)}.fetchOne($0)}
check(sum == 16,"SQLiteData aggregate synchronous entry")
print("BEGIN_AGGREGATE_ASYNC")
let asyncResult=Box<Int?>(nil)
queue.asyncRead { result in let db=try! result.get();asyncResult.value=try! Item.select {$fixtureSum($0.count)}.fetchOne(db) }
pump();check(asyncResult.value == 16,"SQLiteData aggregate async entry")
let grouped=try queue.read { try $0.selectFixtureGroups() }
check(grouped == [9,7], "aggregate separate GROUP BY state")
let empty=try queue.read {try Item.where {$0.id.eq(-1)}.select {$fixtureSum($0.count)}.fetchOne($0)}
check(empty == 0, "aggregate empty input")
print("SQLITEDATA_BROWSER_CONTRACT_OK")
extension Database {
 func selectFixtureGroups() throws -> [Int] { try Int.fetchAll(self,sql:"SELECT fixtureSum(count) FROM items GROUP BY id ORDER BY id") }
}
