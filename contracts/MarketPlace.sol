// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/access/Ownable.sol";

contract MarketPlace is Ownable {
    // Fee config
    uint256 public CREATE_AGENT_FEE = 0.008 ether;
    uint256 public ADD_UTILITY_FEE = 0.8 ether;
    address public FEE_RECEIVER;

    mapping(string => address) _mapAgents;
    mapping(string => string[]) _mapUtilitys;

    event AgentCreated(address owner, uint256 fee, string agentName);
    event UtilityAdded(
        address owner,
        uint256 fee,
        string aiName,
        string utilityName
    );

    constructor() Ownable(msg.sender) {
        FEE_RECEIVER = msg.sender;
    }

    function createAgent(string calldata _agentName) public payable {
        require(
            _mapAgents[_agentName] == address(0),
            "Agent name already exists"
        );
        require(msg.value >= CREATE_AGENT_FEE, "Insufficient balance!");

        (bool success, ) = FEE_RECEIVER.call{value: CREATE_AGENT_FEE}("");
        require(success, "Fee transfer failed");
        _mapAgents[_agentName] = msg.sender;
        emit AgentCreated(msg.sender, CREATE_AGENT_FEE, _agentName);
    }

    function addUltility(
        string calldata _agentName,
        string calldata _utilityName
    ) public payable {
        require(_mapAgents[_agentName] == msg.sender, "Not creator");
        require(
            isUtilityNameExists(_agentName, _utilityName) == false,
            "Agent had been add this utility"
        );
        require(msg.value >= ADD_UTILITY_FEE, "Insufficient balance!");
        (bool success, ) = FEE_RECEIVER.call{value: ADD_UTILITY_FEE}("");
        require(success, "Fee transfer failed");

        _mapUtilitys[_agentName].push(_utilityName);
        emit UtilityAdded(
            msg.sender,
            ADD_UTILITY_FEE,
            _agentName,
            _utilityName
        );
    }

    function isUtilityNameExists(
        string calldata _agentName,
        string calldata _ultilityName
    ) private view returns (bool) {
        string[] memory utilities = _mapUtilitys[_agentName];
        for (uint256 i = 0; i < utilities.length; i++) {
            if (
                keccak256(bytes(utilities[i])) ==
                keccak256(bytes(_ultilityName))
            ) {
                return true;
            }
        }
        return false;
    }

    function setCreateAgentFee(uint256 newFee) public onlyOwner {
        CREATE_AGENT_FEE = newFee;
    }

    function setCreateUtilityFee(uint256 newFee) public onlyOwner {
        ADD_UTILITY_FEE = newFee;
    }

    function setFeeReceiver(address _address) public onlyOwner {
        require(_address != address(0), "Invalid address!");
        FEE_RECEIVER = _address;
    }
}
