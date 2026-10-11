# Firestore: collections that are locked down (archived rules)

`firestore.rules` now allows **one** collection, `users`. Everything else is denied to
everyone, owners included. The app never reads or writes `products`, `inventory`,
`orders`, `deliveries` or `refunds` in Firestore; that data lives in Supabase Postgres
(RLS + `SECURITY DEFINER` functions). The rules that used to guard those collections are
kept below **for reference only**. They are not deployed.

## Why they were removed

Live rules on collections nothing uses are pure attack surface:

* Any signed-in customer could create arbitrary `orders` and `refunds` documents (no field
  allow-list, so `total: 0` or `paymentStatus: 'paid'` were accepted).
* `refunds` could be read by **any** staff member across **all** branches, unlike every
  other branch-scoped rule.
* A future screen pointed at these collections would have trusted client-written data.

## Defects in the archived rules (fix before reusing any of it)

1. **No field allow-lists on create.** Rules cannot recompute totals from line items;
   without a Cloud Function a client controls price fields. Supabase already enforces this
   in `place_order`; do not rebuild it in Firestore.
2. **`refunds` read is not branch-scoped** (`isStaffOrOwner()` only).
3. **`refunds` create does not check the order belongs to the customer** or constrain the
   amount, and nothing stops several refund documents per order.
4. **Staff status changes have no state machine.** Staff could set any status from any
   status; Postgres enforces transitions with triggers.
5. **`inventory` quantity writes are unaudited** and unbatched (Supabase has FEFO batches and
   a movement ledger).
6. `inMyBranch` compares a branch **name** string, while Supabase identifies branches by
   UUID: two sources of truth.

## Before re-enabling a collection

Add the rule, then add emulator tests for every role (signed-out, customer, staff, rider,
owner, **deactivated** staff and owner), including create/update/delete and list queries, and
remove that collection from `DENIED_COLLECTIONS` in `firestore-tests/rules.test.js` in the
same change.

## Archived helpers (they used `isStaff()` etc., now removed from the rules)

```
    function isStaff()    { return hasRole('staff'); }
    function isRider()    { return hasRole('delivery'); }
    function isCustomer() { return hasRole('customer'); }
    function isStaffOrOwner() { return isStaff() || isOwner(); }

    // Owner sees every branch; staff only their own assigned branch.
    function inMyBranch(branch) {
      return isOwner() ||
             (isStaff() && me().get('branch', null) != null && me().get('branch', null) == branch);
    }
```

## Archived collection rules

```
    // --------------------------------------------------------------- products
    // Public catalog (guests browse the store). Only the Owner manages
    // products, prices and variants — Staff cannot change prices.
    match /products/{productId} {
      allow read: if true;
      allow create, update, delete: if isOwner();
    }

    // -------------------------------------------------------------- inventory
    // Branch-scoped stock. Staff read/adjust only their own branch's batches;
    // Owner all branches. Riders and customers have no access.
    match /inventory/{batchId} {
      allow read: if isStaffOrOwner() && inMyBranch(resource.data.branch);

      allow create: if isStaffOrOwner() &&
        inMyBranch(request.resource.data.branch) &&
        request.resource.data.quantity is int &&
        request.resource.data.quantity >= 0;

      // Branch cannot be changed by staff (no moving stock to another branch).
      allow update: if isStaffOrOwner() &&
        inMyBranch(resource.data.branch) &&
        inMyBranch(request.resource.data.branch) &&
        (isOwner() || request.resource.data.branch == resource.data.branch) &&
        request.resource.data.quantity is int &&
        request.resource.data.quantity >= 0;

      allow delete: if isOwner();
    }

    // ----------------------------------------------------------------- orders
    // Money/ownership fields are set at creation and are immutable for
    // everyone except the Owner. NOTE: line-item prices are supplied by the
    // client; rules cannot recompute totals from arrays. Enforcing price
    // integrity needs a Cloud Function (see SECURITY.md).
    match /orders/{orderId} {
      allow read: if isOwner() ||
        (isStaff() && inMyBranch(resource.data.branch)) ||
        (isRider() && resource.data.get('riderId', null) == request.auth.uid) ||
        (isCustomer() && resource.data.get('customerId', null) == request.auth.uid);

      // A customer can only create an order for THEMSELVES, in 'pending', and
      // cannot pre-assign a rider. Staff create counter (POS) orders for their
      // own branch.
      allow create:
        if (isCustomer() &&
              request.resource.data.customerId == request.auth.uid &&
              request.resource.data.status == 'pending' &&
              !request.resource.data.keys().hasAny(['riderId']))
        || (isStaffOrOwner() &&
              inMyBranch(request.resource.data.branch) &&
              request.resource.data.status in ['pending', 'confirmed', 'completed']);

      // Staff: status only, own branch. Assigned rider: status only, and only
      // to out-for-delivery / completed. Owner: full edit.
      allow update: if isOwner() ||
        (isStaff() && inMyBranch(resource.data.branch) &&
          changedKeys().hasOnly(['status', 'updatedAt']) &&
          request.resource.data.status in
            ['pending', 'confirmed', 'preparing', 'outForDelivery', 'completed', 'cancelled']) ||
        (isRider() && resource.data.get('riderId', null) == request.auth.uid &&
          changedKeys().hasOnly(['status', 'updatedAt']) &&
          request.resource.data.status in ['outForDelivery', 'completed']);

      allow delete: if isOwner();
    }

    // -------------------------------------------------------------- deliveries
    // The Owner dispatches deliveries; the assigned rider updates progress.
    match /deliveries/{deliveryId} {
      allow read: if isOwner() ||
        (isStaff() && inMyBranch(resource.data.get('branch', null))) ||
        (isRider() && resource.data.get('riderId', null) == request.auth.uid) ||
        (isCustomer() && resource.data.get('customerId', null) == request.auth.uid);

      allow create, delete: if isOwner();

      allow update: if isOwner() ||
        (isRider() && resource.data.get('riderId', null) == request.auth.uid &&
          changedKeys().hasOnly(['status', 'stops', 'updatedAt']));
    }

    // ---------------------------------------------------------------- refunds
    // Customers request refunds for themselves; only the Owner decides them.
    match /refunds/{refundId} {
      allow read: if isStaffOrOwner() ||
        (isCustomer() && resource.data.get('customerId', null) == request.auth.uid);

      allow create: if isCustomer() &&
        request.resource.data.customerId == request.auth.uid &&
        request.resource.data.status == 'pending';

      allow update, delete: if isOwner();
    }
```
