// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library SafeArray {
    function quickSort(
        uint256[] memory arr,
        int256 left,
        int256 right
    ) internal pure returns (bool) {
        int256 i = left;
        int256 j = right;
        if (i == j) return true;
        uint256 pivot = arr[uint256(left + (right - left) / 2)];
        while (i <= j) {
            while (arr[uint256(i)] < pivot) i++;
            while (pivot < arr[uint256(j)]) j--;
            if (i <= j) {
                (arr[uint256(i)], arr[uint256(j)]) = (
                    arr[uint256(j)],
                    arr[uint256(i)]
                );
                i++;
                j--;
            }
        }
        if (left < j) quickSort(arr, left, j);
        if (i < right) quickSort(arr, i, right);
        return true;
    }

    function sort(
        uint256[] memory data
    ) public pure returns (uint256[] memory) {
        quickSort(data, int256(0), int256(data.length - 1));
        return data;
    }

    function clear(uint256[] memory data) public pure returns (bool) {
        while (data.length > 0) {
            delete data[data.length - 1];
        }
        return true;
    }
}
