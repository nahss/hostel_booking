module hostel_booking::hostel_booking {

    // Imports
    use sui::transfer;
    use sui::sui::SUI;
    use std::string::{Self, String};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::object::{Self, UID, ID};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::table::{Self, Table};
    // use std::option::{Option, none, some, is_some, contains, borrow};

    // Errors
    const EInsufficientFunds: u64 = 1;
    const EInvalidCoin: u64 = 2;
    const ENotStudent: u64 = 3;
    // const EInvalidHostel: u64 = 4;
    const EInvalidRoom: u64 = 5;
    const ENotInstitution: u64 = 6;
    const EInvalidHostelBooking: u64 = 7;

    // HostelBooking Institution 

    struct Institution has key {
        id: UID,
        name: String,
        student_fees: Table<ID, u64>, // student_id -> fees
        balance: Balance<SUI>,
        memos: Table<ID, RoomMemo>, // student_id -> memo
        institution: address
    }

    // Student

    struct Student has key {
        id: UID,
        name: String,
        student: address,
        institution_id: ID,
        balance: Balance<SUI>,
    }

    // RoomMemo

    struct RoomMemo has key, store {
        id: UID,
        room_id: ID,
        semester_payment: u64,
        student_fee: u64, //This is the mimimum fee that the student has to pay
        institution: address 
    }

    // Hostel

    struct HostelRoom has key {
        id: UID,
        name: String,
        room_size : u64,
        institution: address,
        beds_available: u64,
    }

    // Record of Hostel Booking

    struct BookingRecord has key, store {
        id: UID,
        student_id: ID,
        room_id: ID,
        student: address,
        institution: address,
        paid_fee: u64,
        semester_payment: u64,
        booking_time: u64
    }

    // Create a new Institution object 

    public fun create_institution(ctx:&mut TxContext, name: String) {
        let institution = Institution {
            id: object::new(ctx),
            name: name,
            student_fees: table::new<ID, u64>(ctx),
            balance: balance::zero<SUI>(),
            memos: table::new<ID, RoomMemo>(ctx),
            institution: tx_context::sender(ctx)
        };

        transfer::share_object(institution);
    }

    // Create a new Student object

    public fun create_student(ctx:&mut TxContext, name: String, institution_address: address) {
        let institution_id_: ID = object::id_from_address(institution_address);
        let student = Student {
            id: object::new(ctx),
            name: name,
            student: tx_context::sender(ctx),
            institution_id: institution_id_,
            balance: balance::zero<SUI>(),
        };

        transfer::share_object(student);
    }

    // create a memo for a room

    public fun create_room_memo(
        institution: &mut Institution,
        semester_payment: u64,
        student_fee: u64,
        room_name: vector<u8>,
        room_size: u64,
        beds_available: u64,
        ctx: &mut TxContext
    ): HostelRoom{
        assert!(institution.institution == tx_context::sender(ctx), ENotInstitution);
        let room = HostelRoom {
            id: object::new(ctx),
            name: string::utf8(room_name),
            room_size: room_size,
            institution: institution.institution,
            beds_available: beds_available
        };
        let memo = RoomMemo {
            id: object::new(ctx),
            room_id: object::uid_to_inner(&room.id),
            semester_payment: semester_payment,
            student_fee: student_fee, //Minimum fee that the student has to pay
            institution: institution.institution
        };

        table::add<ID, RoomMemo>(&mut institution.memos, object::uid_to_inner(&room.id), memo);

        room
    }

    // Book a room

    public fun book_room(
        institution: &mut Institution,
        student: &mut Student,
        room: &mut HostelRoom,
        room_memo_id: ID,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(institution.institution == tx_context::sender(ctx), ENotInstitution);
        assert!(student.institution_id == object::id_from_address(institution.institution), ENotStudent);
        assert!(table::contains<ID, RoomMemo>(&institution.memos, room_memo_id), EInvalidHostelBooking);
        assert!(room.institution == institution.institution, EInvalidRoom);
        assert!(room.beds_available > 0, EInvalidRoom);
        let room_id = &room.id;
        let memo = table::borrow<ID, RoomMemo>(&institution.memos, room_memo_id);

        
        let student_fee = memo.student_fee;
        let semester_payment = memo.semester_payment;
        let booking_time = clock::timestamp_ms(clock);
        let booking_record = BookingRecord {
            id: object::new(ctx),
            student_id: object::uid_to_inner(&student.id),
            room_id: object::uid_to_inner(room_id),
            student: student.student,
            institution: institution.institution,
            paid_fee: student_fee,
            semester_payment: semester_payment,
            booking_time: booking_time
        };

        transfer::public_freeze_object(booking_record);
        // deduct the student fee from the student balance and add it to the institution balance
        let total_pay = student_fee + semester_payment;
        assert!(total_pay <= balance::value(&student.balance), EInsufficientFunds);
        let amount_to_pay = coin::take(&mut student.balance, total_pay, ctx);
        let same_amount_to_pay = coin::take(&mut student.balance, total_pay, ctx);
        assert!(coin::value(&amount_to_pay) > 0, EInvalidCoin);
        assert!(coin::value(&same_amount_to_pay) > 0, EInvalidCoin);

        transfer::public_transfer(amount_to_pay, institution.institution);
        
        // calculate total pay and deduct it from the student balance
        room.beds_available = room.beds_available - 1;

        // remove Memo from the institution
        let RoomMemo{id: _room_id, room_id: _, semester_payment: _, student_fee: _, institution: _} = table::remove<ID, RoomMemo>(&mut institution.memos, room_memo_id);
        object::delete(_room_id);

        same_amount_to_pay
    }

    // Student adding funds to their account

    public fun top_up_student_balance(
        student: &mut Student,
        amount: Coin<SUI>,
        ctx: &mut TxContext
    ){
        assert!(student.student == tx_context::sender(ctx), ENotStudent);
        balance::join(&mut student.balance, coin::into_balance(amount));
    }

    // add the Payment fee to the institution balance

    public fun top_up_institution_balance(
        institution: &mut Institution,
        student: &mut Student,
        room: &mut HostelRoom,
        room_memo_id: ID,
        clock: &Clock,
        ctx: &mut TxContext
    ){
        // Can only be called by the student
        assert!(student.student == tx_context::sender(ctx), ENotStudent);
        let (amount_to_pay) = book_room(institution, student, room, room_memo_id, clock, ctx);
        balance::join(&mut institution.balance, coin::into_balance(amount_to_pay));
    }

    // Get the balance of the institution

    public fun get_institution_balance(institution: &Institution) : &Balance<SUI> {
        &institution.balance
    }

    // Institution can withdraw the balance

    public fun withdraw_funds(
        institution: &mut Institution,
        amount: u64,
        ctx: &mut TxContext
    ){
        assert!(institution.institution == tx_context::sender(ctx), ENotInstitution);
        assert!(amount <= balance::value(&institution.balance), EInsufficientFunds);
        let amount_to_withdraw = coin::take(&mut institution.balance, amount, ctx);
        transfer::public_transfer(amount_to_withdraw, institution.institution);
    }
    
    // Transfer the Ownership of the room to the student

    public entry fun transfer_room_ownership(
        student: &Student,
        room: HostelRoom,
    ){
        transfer::transfer(room, student.student);
    }


    // Student Returns the room ownership
    // Only increment the beds available in the room

    public fun return_room(
        institution: &mut Institution,
        student: &mut Student,
        room: &mut HostelRoom,
        ctx: &mut TxContext
    ) {
        assert!(institution.institution == tx_context::sender(ctx), ENotInstitution);
        assert!(student.institution_id == object::id_from_address(institution.institution), ENotStudent);
        assert!(room.institution == institution.institution, EInvalidRoom);

        room.beds_available = room.beds_available + 1;
    }
    
  

    
}
