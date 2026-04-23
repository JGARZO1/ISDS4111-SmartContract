// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PropertyRental
 * @notice A smart contract for managing property rental agreements on the blockchain.
 *         Landlords can list properties, tenants can rent them, and payments are
 *         handled transparently on-chain.
 */
contract PropertyRental {

    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    address public owner;                  // Contract owner (platform administrator)
    uint256 public platformFeePercent;     // Platform fee as a percentage (e.g., 2 = 2%)
    uint256 public propertyCount;          // Total number of properties listed

    struct Property {
        uint256 id;
        address payable landlord;
        string description;
        uint256 rentPerMonth;   // in wei
        uint256 depositAmount;  // in wei
        bool isAvailable;
        address tenant;
        uint256 leaseStart;
        uint256 leaseEnd;
        uint256 depositHeld;
    }

    mapping(uint256 => Property) public properties;
    mapping(address => uint256) public pendingWithdrawals;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event PropertyListed(
        uint256 indexed propertyId,
        address indexed landlord,
        string description,
        uint256 rentPerMonth,
        uint256 depositAmount
    );

    event PropertyRented(
        uint256 indexed propertyId,
        address indexed tenant,
        uint256 leaseStart,
        uint256 leaseEnd,
        uint256 depositPaid
    );

    event RentPaid(
        uint256 indexed propertyId,
        address indexed tenant,
        uint256 amount,
        uint256 timestamp
    );

    event LeaseTerminated(
        uint256 indexed propertyId,
        address indexed tenant,
        uint256 depositReturned
    );

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /// @dev Restricts function access to the contract owner only.
    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the contract owner");
        _;
    }

    /// @dev Restricts function access to the landlord of a specific property.
    modifier onlyLandlord(uint256 _propertyId) {
        require(
            msg.sender == properties[_propertyId].landlord,
            "Caller is not the landlord of this property"
        );
        _;
    }

    /// @dev Restricts function access to the current tenant of a specific property.
    modifier onlyTenant(uint256 _propertyId) {
        require(
            msg.sender == properties[_propertyId].tenant,
            "Caller is not the tenant of this property"
        );
        _;
    }

    /// @dev Ensures the property exists and is currently available for rent.
    modifier propertyAvailable(uint256 _propertyId) {
        require(_propertyId > 0 && _propertyId <= propertyCount, "Property does not exist");
        require(properties[_propertyId].isAvailable, "Property is not available for rent");
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @notice Initializes the contract with the deploying address as owner
     *         and sets a default platform fee.
     * @param _platformFeePercent The percentage fee the platform takes from rent (e.g., 2 for 2%).
     */
    constructor(uint256 _platformFeePercent) {
        require(_platformFeePercent <= 10, "Platform fee cannot exceed 10%");
        owner = msg.sender;
        platformFeePercent = _platformFeePercent;
        propertyCount = 0;
    }

    // -------------------------------------------------------------------------
    // Public Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Lists a new property for rent.
     * @param _description A short description of the property.
     * @param _rentPerMonth Monthly rent amount in wei.
     * @param _depositAmount Security deposit amount in wei.
     */
    function listProperty(
        string memory _description,
        uint256 _rentPerMonth,
        uint256 _depositAmount
    ) public {
        require(_rentPerMonth > 0, "Rent must be greater than zero");
        require(_depositAmount > 0, "Deposit must be greater than zero");
        require(bytes(_description).length > 0, "Description cannot be empty");

        propertyCount++;

        properties[propertyCount] = Property({
            id: propertyCount,
            landlord: payable(msg.sender),
            description: _description,
            rentPerMonth: _rentPerMonth,
            depositAmount: _depositAmount,
            isAvailable: true,
            tenant: address(0),
            leaseStart: 0,
            leaseEnd: 0,
            depositHeld: 0
        });

        emit PropertyListed(propertyCount, msg.sender, _description, _rentPerMonth, _depositAmount);
    }

    /**
     * @notice Rents an available property by paying the deposit upfront.
     *         The lease duration is specified in months.
     * @param _propertyId The ID of the property to rent.
     * @param _leaseMonths The number of months for the lease.
     */
    function rentProperty(uint256 _propertyId, uint256 _leaseMonths)
        public
        payable
        propertyAvailable(_propertyId)
    {
        Property storage prop = properties[_propertyId];
        require(_leaseMonths > 0, "Lease must be at least one month");
        require(msg.value == prop.depositAmount, "Must send exact deposit amount");
        require(msg.sender != prop.landlord, "Landlord cannot rent their own property");

        prop.isAvailable = false;
        prop.tenant = msg.sender;
        prop.leaseStart = block.timestamp;
        prop.leaseEnd = block.timestamp + (_leaseMonths * 30 days);
        prop.depositHeld = msg.value;

        emit PropertyRented(_propertyId, msg.sender, prop.leaseStart, prop.leaseEnd, msg.value);
    }

    /**
     * @notice Allows a tenant to pay monthly rent for their rented property.
     *         The platform fee is deducted and the remainder goes to the landlord.
     * @param _propertyId The ID of the property to pay rent for.
     */
    function payRent(uint256 _propertyId)
        public
        payable
        onlyTenant(_propertyId)
    {
        Property storage prop = properties[_propertyId];
        require(!prop.isAvailable, "Property is not currently rented");
        require(block.timestamp <= prop.leaseEnd, "Lease has expired");
        require(msg.value == prop.rentPerMonth, "Must send exact rent amount");

        uint256 fee = (msg.value * platformFeePercent) / 100;
        uint256 landlordShare = msg.value - fee;

        pendingWithdrawals[prop.landlord] += landlordShare;
        pendingWithdrawals[owner] += fee;

        emit RentPaid(_propertyId, msg.sender, msg.value, block.timestamp);
    }

    /**
     * @notice Terminates the lease and returns the deposit to the tenant.
     *         Can be called by the landlord after the lease end date.
     * @param _propertyId The ID of the property.
     */
    function terminateLease(uint256 _propertyId)
        public
        onlyLandlord(_propertyId)
    {
        Property storage prop = properties[_propertyId];
        require(!prop.isAvailable, "Property is not currently rented");
        require(block.timestamp >= prop.leaseEnd, "Lease period has not ended yet");

        uint256 depositToReturn = prop.depositHeld;
        address formerTenant = prop.tenant;

        prop.isAvailable = true;
        prop.tenant = address(0);
        prop.leaseStart = 0;
        prop.leaseEnd = 0;
        prop.depositHeld = 0;

        pendingWithdrawals[formerTenant] += depositToReturn;

        emit LeaseTerminated(_propertyId, formerTenant, depositToReturn);
    }

    /**
     * @notice Allows landlords, tenants, and the owner to withdraw their
     *         accumulated balances from the contract.
     */
    function withdraw() public {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "No funds available to withdraw");

        pendingWithdrawals[msg.sender] = 0;
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Withdrawal failed");
    }

    /**
     * @notice Updates the platform fee percentage. Only callable by the owner.
     * @param _newFee New fee percentage (must be 10% or less).
     */
    function updatePlatformFee(uint256 _newFee) public onlyOwner {
        require(_newFee <= 10, "Platform fee cannot exceed 10%");
        platformFeePercent = _newFee;
    }

    /**
     * @notice Returns details of a specific property.
     * @param _propertyId The ID of the property to look up.
     */
    function getProperty(uint256 _propertyId)
        public
        view
        returns (
            address landlord,
            string memory description,
            uint256 rentPerMonth,
            uint256 depositAmount,
            bool isAvailable,
            address tenant,
            uint256 leaseEnd
        )
    {
        require(_propertyId > 0 && _propertyId <= propertyCount, "Property does not exist");
        Property storage prop = properties[_propertyId];
        return (
            prop.landlord,
            prop.description,
            prop.rentPerMonth,
            prop.depositAmount,
            prop.isAvailable,
            prop.tenant,
            prop.leaseEnd
        );
    }

    // -------------------------------------------------------------------------
    // Ownership Transfer
    // -------------------------------------------------------------------------

    /**
     * @notice Transfers ownership of the contract to a new address.
     * @param _newOwner The address of the new owner.
     */
    function transferOwnership(address _newOwner) public onlyOwner {
        require(_newOwner != address(0), "New owner cannot be the zero address");
        require(_newOwner != owner, "New owner must be a different address");

        address previousOwner = owner;
        owner = _newOwner;

        emit OwnershipTransferred(previousOwner, _newOwner);
    }
}
