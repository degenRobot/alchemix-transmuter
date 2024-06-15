pragma solidity 0.8.18;


interface ITransmuter {
    function deposit(uint256 _amount, address _owner) external;
    function claim(uint256 _amount, address _owner) external;

    function getClaimableBalance(address _owner) external view returns (uint256);
    function getExchangedBalance(address _owner) external view returns (uint256);
    function getUnexchangedBalance(address _owner) external view returns (uint256);
    

}